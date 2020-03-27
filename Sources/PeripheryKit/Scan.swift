import Foundation
import PathKit
import TSCBasic

public final class Scan: Injectable {
    public static func make() -> Self {
        return self.init(configuration: inject(),
                         xcodebuild: inject(),
                         logger: inject())
    }

    private let configuration: Configuration
    private let xcodebuild: Xcodebuild
    private let logger: Logger

    public required init(configuration: Configuration,
                         xcodebuild: Xcodebuild,
                         logger: Logger) {
        self.configuration = configuration
        self.xcodebuild = xcodebuild
        self.logger = logger
    }

    fileprivate var indexStoreLibCache = LazyCache(createIndexStoreLib)
    private func createIndexStoreLib() -> Result<AbsolutePath, Error> {
        if let toolchainDir = ProcessEnv.vars["TOOLCHAIN_DIR"] {
            return .success(AbsolutePath(toolchainDir).appending(components: "usr", "lib", "libIndexStore.dylib"))
        }
        return Result {
            let developerDirStr = try Process.checkNonZeroExit(arguments: ["/usr/bin/xcode-select", "--print-path"])
            return AbsolutePath(developerDirStr).appending(
                components: "Toolchains", "XcodeDefault.xctoolchain",
                            "usr", "lib", "libIndexStore.dylib"
            )
        }
    }

    public func perform() throws -> ScanResult {
        guard configuration.workspace != nil || configuration.project != nil else {
            let message = "You must supply either the --workspace or --project option. If your project uses an .xcworkspace to integrate multiple projects, then supply the --workspace option. Otherwise, supply the --project option."
            throw PeripheryKitError.usageError(message)
        }

        if configuration.workspace != nil && configuration.project != nil {
            let message = "You must supply either the --workspace or --project option, not both. If your project uses an .xcworkspace to integrate multiple projects, then supply the --workspace option. Otherwise, supply the --project option."
            throw PeripheryKitError.usageError(message)
        }

        guard !configuration.schemes.isEmpty else {
            throw PeripheryKitError.usageError("The '--schemes' option is required.")
        }

        guard !configuration.targets.isEmpty else {
            throw PeripheryKitError.usageError("The '--targets' option is required.")
        }

        if configuration.saveBuildLog != nil && configuration.useBuildLog != nil {
            throw PeripheryKitError.usageError("The '--save-build-log' and '--use-build-log' options are mutually exclusive. Please first save the build log with '--save-build-log <key>' and then use it with '--use-build-log <key>'.")
        }

        logger.debug("[version] \(PeripheryVersion)")
        let configYaml = try configuration.asYaml()
        logger.debug("[configuration]\n--- # .periphery.yml\n\(configYaml.trimmed)\n")

        let project: XcodeProjectlike

        if configuration.outputFormat.supportsAuxiliaryOutput {
            let asterisk = colorize("*", .boldGreen)
            logger.info("\(asterisk) Inspecting project configuration...")
        }

        if let workspacePath = configuration.workspace {
            project = try Workspace.make(path: workspacePath)
        } else if let projectPath = configuration.project {
            project = try Project.make(path: projectPath)
        } else {
            throw PeripheryKitError.usageError("Expected --workspace or --project option.")
        }

        // Ensure targets are part of the project
        let targets = project.targets.filter { configuration.targets.contains($0.name) }
        let missingTargetNames = Set(configuration.targets).subtracting(targets.map { $0.name })

        if let name = missingTargetNames.first {
            throw PeripheryKitError.invalidTarget(name: name, project: project.path.lastComponent)
        }

        try targets.forEach { try $0.identifyModuleName() }
        try TargetSourceFileUniquenessChecker.check(targets: targets)

        let buildPlan = try BuildPlan.make(targets: targets)
        let graph = SourceGraph()

        if configuration.outputFormat.supportsAuxiliaryOutput {
            let asterisk = colorize("*", .boldGreen)
            logger.info("\(asterisk) Indexing...")
        }

        // FIXME: Add option to specify index-store-path
        let buildRootPath = AbsolutePath(ProcessEnv.vars["BUILD_ROOT"]!)
        let indexStorePath = buildRootPath
            .parentDirectory.parentDirectory
            .appending(components: "Index", "DataStore")
        let indexStore = try IndexStore.open(
            store: indexStorePath,
            api: IndexStoreAPI(dylib: indexStoreLibCache.getValue(self).get())
        )
        try Indexer.perform(buildPlan: buildPlan, indexStore: indexStore, graph: graph)

        if configuration.outputFormat.supportsAuxiliaryOutput {
            let asterisk = colorize("*", .boldGreen)
            logger.info("\(asterisk) Analyzing...\n")
        }

        try Analyzer.perform(graph: graph)

        let reducer = RedundantDeclarationReducer(declarations: graph.dereferencedDeclarations)
        let reducedDeclarations = reducer.reduce()

        return ScanResult(declarations: reducedDeclarations, graph: graph)
    }
}
