//
//  Headless.swift
//  ProjectTool
//
//  AIA-0970: build, run and drive the headless ML Browser in the Simulator. Since AIA-1008 the
//  commands are HeadlessKit's `HeadlessTool`; `MLBrowserHeadless` (ProjectToolCore) is ML Browser's.
//

import ArgumentParser
import Foundation
import HeadlessSimulatorLauncher
import ProjectToolCore

/// `ProjectTool headless …` — see `specification/HEADLESS.md`. Every argument goes to the kit
/// verbatim, `--help` included: the kit parses the command line and prints the usage.
struct Headless: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "headless",
		abstract: "Build, run and drive the headless ML Browser (AIA-0970).",
		helpNames: []
	)

	@Argument(parsing: .allUnrecognized, help: "The kit's command line: build, up, exec, down, reset, test or help.")
	var arguments: [String] = []

	func run() async throws {
		let project = MLBrowserHeadless(runTool: { try runShellCommand($0, arguments: $1) }, processList: processList)
		do {
			try await HeadlessTool.run(arguments, project: project)
		} catch {
			if let message = HeadlessTool.message(for: error) {
				FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
			}
			throw ExitCode(HeadlessTool.exitCode(for: error))
		}
	}
}

/// `ps -axo command=`: every running command line, for the check that no build uses the DerivedData.
@Sendable private func processList() throws -> String {
	let task = Process()
	task.executableURL = URL(fileURLWithPath: "/bin/ps")
	task.arguments = ["-axo", "command="]
	let output = Pipe()
	task.standardOutput = output
	task.standardError = FileHandle.nullDevice
	try task.run()
	let data = output.fileHandleForReading.readDataToEndOfFile()
	task.waitUntilExit()
	guard task.terminationStatus == 0 else {
		throw ValidationError("/bin/ps -axo command= failed with exit code \(task.terminationStatus)")
	}
	return String(bytes: data, encoding: .utf8) ?? ""
}
