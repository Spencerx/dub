/**
	LDC compiler support.

	Copyright: © 2013-2013 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dub.compilers.ldc;

import dub.compilers.compiler;
import dub.compilers.utils;
import dub.internal.utils;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.inet.path;
import dub.internal.logging;

import std.algorithm;
import std.array;
import std.exception;
import std.typecons;


class LDCCompiler : Compiler {
	private static immutable s_options = [
		tuple(BuildOption.debugMode, ["-d-debug"]),
		tuple(BuildOption.releaseMode, ["-release"]),
		tuple(BuildOption.coverage, ["-cov"]),
		tuple(BuildOption.coverageCTFE, ["-cov=ctfe"]),
		tuple(BuildOption.debugInfo, ["-g"]),
		tuple(BuildOption.debugInfoC, ["-gc"]),
		tuple(BuildOption.alwaysStackFrame, ["-disable-fp-elim"]),
		//tuple(BuildOption.stackStomping, ["-?"]),
		tuple(BuildOption.inline, ["-enable-inlining", "-Hkeep-all-bodies"]),
		tuple(BuildOption.noBoundsCheck, ["-boundscheck=off"]),
		tuple(BuildOption.optimize, ["-O3"]),
		tuple(BuildOption.profile, ["-fdmd-trace-functions"]),
		tuple(BuildOption.unittests, ["-unittest"]),
		tuple(BuildOption.verbose, ["-v"]),
		tuple(BuildOption.ignoreUnknownPragmas, ["-ignore"]),
		tuple(BuildOption.syntaxOnly, ["-o-"]),
		tuple(BuildOption.warnings, ["-wi"]),
		tuple(BuildOption.warningsAsErrors, ["-w"]),
		tuple(BuildOption.ignoreDeprecations, ["-d"]),
		tuple(BuildOption.deprecationWarnings, ["-dw"]),
		tuple(BuildOption.deprecationErrors, ["-de"]),
		tuple(BuildOption.property, ["-property"]),
		//tuple(BuildOption.profileGC, ["-?"]),
		tuple(BuildOption.betterC, ["-betterC"]),
		tuple(BuildOption.lowmem, ["-lowmem"]),
		tuple(BuildOption.color, ["-enable-color"]),

		tuple(BuildOption._docs, ["-Dd=docs"]),
		tuple(BuildOption._ddox, ["-Xf=docs.json", "-Dd=__dummy_docs"]),
	];

	@property string name() const { return "ldc"; }

	enum ldcVersionRe = `^version\s+v?(\d+\.\d+\.\d+[A-Za-z0-9.+-]*)`;

	unittest {
		import std.regex : matchFirst, regex;
		auto probe = `
binary    /usr/bin/ldc2
version   1.11.0 (DMD v2.081.2, LLVM 6.0.1)
config    /etc/ldc2.conf (x86_64-pc-linux-gnu)
`;
		auto re = regex(ldcVersionRe, "m");
		auto c = matchFirst(probe, re);
		assert(c && c.length > 1 && c[1] == "1.11.0");
	}

	string determineVersion(string compiler_binary, string verboseOutput)
	{
		import std.regex : matchFirst, regex;
		auto ver = matchFirst(verboseOutput, regex(ldcVersionRe, "m"));
		return ver && ver.length > 1 ? ver[1] : null;
	}

	BuildPlatform determinePlatform(ref BuildSettings settings, string compiler_binary, string arch_override)
	{
		string[] arch_flags;
		bool arch_override_is_triple = false;
		switch (arch_override) {
			case "": break;
			case "x86": arch_flags = ["-march=x86"]; break;
			case "x86_mscoff": arch_flags = ["-march=x86"]; break;
			case "x86_64": arch_flags = ["-march=x86-64"]; break;
			case "aarch64": arch_flags = ["-march=aarch64"]; break;
			case "powerpc64": arch_flags = ["-march=powerpc64"]; break;
			default:
				if (arch_override.canFind('-')) {
					arch_override_is_triple = true;
					arch_flags = ["-mtriple="~arch_override];
				} else
					throw new UnsupportedArchitectureException(arch_override);
				break;
		}

		auto bp = probePlatform(compiler_binary, arch_flags);

		bool keep_arch = arch_override_is_triple;
		if (!keep_arch && arch_flags.length)
			keep_arch = bp.architecture != probePlatform(compiler_binary, []).architecture;
		settings.maybeAddArchFlags(keep_arch, arch_flags, arch_override);

		return bp;
	}

	void prepareBuildSettings(ref BuildSettings settings, const scope ref BuildPlatform platform, BuildSetting fields = BuildSetting.all) const
	{
		enforceBuildRequirements(settings);

		// Keep the current dflags at the end of the array so that they will overwrite other flags.
		// This allows user $DFLAGS to modify flags added by us.
		const dflagsTail = settings.dflags;
		settings.dflags = [];

		if (!(fields & BuildSetting.options)) {
			foreach (t; s_options)
				if (settings.options & t[0])
					settings.addDFlags(t[1]);
		}

		if (!(fields & BuildSetting.versions)) {
			settings.addDFlags(settings.versions.map!(s => "-d-version="~s)().array());
			settings.versions = null;
		}

		if (!(fields & BuildSetting.debugVersions)) {
			settings.addDFlags(settings.debugVersions.map!(s => "-d-debug="~s)().array());
			settings.debugVersions = null;
		}

		if (!(fields & BuildSetting.importPaths)) {
			settings.addDFlags(settings.importPaths.map!(s => "-I"~s)().array());
			settings.importPaths = null;
		}

		if (!(fields & BuildSetting.cImportPaths)) {
			settings.addDFlags(settings.cImportPaths.map!(s => "-P-I"~s)().array());
			settings.cImportPaths = null;
		}

		if (!(fields & BuildSetting.stringImportPaths)) {
			settings.addDFlags(settings.stringImportPaths.map!(s => "-J"~s)().array());
			settings.stringImportPaths = null;
		}

		if (!(fields & BuildSetting.sourceFiles)) {
			settings.addDFlags(settings.sourceFiles);
			settings.sourceFiles = null;
		}

		if (!(fields & BuildSetting.libs)) {
			resolveLibs(settings, platform);
			settings.addLFlags(settings.libs.map!(l => "-l"~l)().array());
		}

		if (!(fields & BuildSetting.frameworks)) {
			if (platform.isDarwin())
				settings.addLFlags(settings.frameworks.map!(l => ["-framework", l])().joiner.array());
			else
				logDiagnostic("Not a darwin-derived platform, skipping frameworks...");
		}

		if (!(fields & BuildSetting.lflags)) {
			settings.addDFlags(lflagsToDFlags(settings.lflags));
			settings.lflags = null;
		}

		if (settings.options & BuildOption.pic) {
			if (platform.isWindows()) {
				/* This has nothing to do with PIC, but as the PIC option is exclusively
				 * set internally for code that ends up in a dynamic library, explicitly
				 * specify what `-shared` defaults to (`-shared` can't be used when
				 * compiling only, without linking).
				 * *Pre*pending the flags enables the user to override them.
				 */
				settings.prependDFlags("-fvisibility=public", "-dllimport=all");
			} else {
				settings.addDFlags("-relocation-model=pic");
			}
		}

		settings.addDFlags(dflagsTail);

		assert(fields & BuildSetting.dflags);
		assert(fields & BuildSetting.copyFiles);
	}

	void extractBuildOptions(ref BuildSettings settings) const
	{
		Appender!(string[]) newflags;
		next_flag: foreach (f; settings.dflags) {
			foreach (t; s_options)
				if (t[1].canFind(f)) {
					settings.options |= t[0];
					continue next_flag;
				}
			if (f.startsWith("-d-version=")) settings.addVersions(f[11 .. $]);
			else if (f.startsWith("-d-debug=")) settings.addDebugVersions(f[9 .. $]);
			else newflags ~= f;
		}
		settings.dflags = newflags.data;
	}

	string getTargetFileName(in BuildSettings settings, in BuildPlatform platform)
	const {
		assert(settings.targetName.length > 0, "No target name set.");

		const p = platform.platform;
		final switch (settings.targetType) {
			case TargetType.autodetect: assert(false, "Configurations must have a concrete target type.");
			case TargetType.none: return null;
			case TargetType.sourceLibrary: return null;
			case TargetType.executable:
				if (p.canFind("windows"))
					return settings.targetName ~ ".exe";
				else if (p.canFind("wasm"))
					return settings.targetName ~ ".wasm";
				else return settings.targetName.idup;
			case TargetType.library:
			case TargetType.staticLibrary:
				if (p.canFind("windows") && !p.canFind("mingw"))
					return settings.targetName ~ ".lib";
				else return "lib" ~ settings.targetName ~ ".a";
			case TargetType.dynamicLibrary:
				if (p.canFind("windows"))
					return settings.targetName ~ ".dll";
				else if (p.canFind("darwin"))
					return "lib" ~ settings.targetName ~ ".dylib";
				else return "lib" ~ settings.targetName ~ ".so";
			case TargetType.object:
				if (p.canFind("windows"))
					return settings.targetName ~ ".obj";
				else return settings.targetName ~ ".o";
		}
	}

	void setTarget(ref BuildSettings settings, in BuildPlatform platform, string tpath = null) const
	{
		const targetFileName = getTargetFileName(settings, platform);

		const p = platform.platform;
		final switch (settings.targetType) {
			case TargetType.autodetect: assert(false, "Invalid target type: autodetect");
			case TargetType.none: assert(false, "Invalid target type: none");
			case TargetType.sourceLibrary: assert(false, "Invalid target type: sourceLibrary");
			case TargetType.executable: break;
			case TargetType.library:
			case TargetType.staticLibrary:
				// -oq: name object files uniquely (so the files don't collide)
				settings.addDFlags("-lib", "-oq");
				// -cleanup-obj (supported since LDC v1.1): remove object files after archiving to static lib
				if (platform.frontendVersion >= 2071) {
					settings.addDFlags("-cleanup-obj");
				}
				if (platform.frontendVersion < 2095) {
					// Since LDC v1.25, -cleanup-obj defaults to a unique temp -od directory
					// We need to resort to a unique-ish -od directory before that
					settings.addDFlags("-od=" ~ settings.targetPath ~ "/obj");
				}
				break;
			case TargetType.dynamicLibrary:
				settings.addDFlags("-shared");
				addDynamicLibName(settings, platform, targetFileName);
				break;
			case TargetType.object:
				settings.addDFlags("-c");

				// When using wasm-ld on output objects, we need to explicitly
				// not strip dead symbols, otherwise we'll get a linker error.
				// as wasm-ld only works on relocatable objects.
				if (p.canFind("wasm")) {
					settings.addDFlags("--disable-linker-strip-dead");
					settings.addLFlags("-r");
				}
				break;
		}

		if (tpath is null)
			tpath = (NativePath(settings.targetPath) ~ targetFileName).toNativeString();
		settings.addDFlags("-of"~tpath);
	}

	void invoke(in BuildSettings settings, in BuildPlatform platform, void delegate(int, string) output_callback, NativePath cwd)
	{
		auto res_file = getTempFile("dub-build", ".rsp");
		const(string)[] args = settings.dflags;
		if (platform.frontendVersion >= 2066) args ~= "-vcolumns";
		writeFile(res_file, escapeArgs(args).join("\n"));

		logDiagnostic("%s %s", platform.compilerBinary, escapeArgs(args).join(" "));
		string[string] env;
		foreach (aa; [settings.environments, settings.buildEnvironments])
			foreach (k, v; aa)
				env[k] = v;
		invokeTool([platform.compilerBinary, "@"~res_file.toNativeString()], output_callback, cwd, env);
	}

	void invokeLinker(in BuildSettings settings, in BuildPlatform platform, string[] objects, void delegate(int, string) output_callback, NativePath cwd)
	{
		import std.string;
		auto tpath = NativePath(settings.targetPath) ~ getTargetFileName(settings, platform);
		auto args = ["-of"~tpath.toNativeString()];
		const p = platform.platform;

		args ~= objects;
		args ~= settings.sourceFiles;

		// Avoids linker errors due to libraries being specified in the wrong order.
		// However, the wasm-ld linker does not have --no-as-needed and emscripten is
		// implicitly treated as a "linux" platform.
		if (p.canFind("linux") && !p.canFind("emscripten"))
			args ~= "-L--no-as-needed";

		args ~= lflagsToDFlags(settings.lflags);
		args ~= settings.dflags.filter!(f => isLinkerDFlag(f)).array;

		auto res_file = getTempFile("dub-build", ".lnk");
		writeFile(res_file, escapeArgs(args).join("\n"));

		logDiagnostic("%s %s", platform.compilerBinary, escapeArgs(args).join(" "));
		string[string] env;
		foreach (aa; [settings.environments, settings.buildEnvironments])
			foreach (k, v; aa)
				env[k] = v;
		invokeTool([platform.compilerBinary, "@"~res_file.toNativeString()], output_callback, cwd, env);
	}

	string[] lflagsToDFlags(const string[] lflags) const
	{
        return map!(f => "-L"~f)(lflags.filter!(f => f != "")()).array();
	}

	private auto escapeArgs(in string[] args)
	{
		return args.map!(s => s.canFind(' ') ? "\""~s~"\"" : s);
	}

	static bool isLinkerDFlag(string arg)
	{
		if (arg.length > 2 && arg.startsWith("--"))
			arg = arg[1 .. $]; // normalize to 1 leading hyphen

		switch (arg) {
			case "-g", "-gc", "-m32", "-m64", "-mwasm64", "-shared", "-lib",
			     "-betterC", "-disable-linker-strip-dead", "-static", "-r":
				return true;
			default:
				return arg.startsWith("-L")
				    || arg.startsWith("-Xcc=")
				    || arg.startsWith("-defaultlib=")
				    || arg.startsWith("-platformlib=")
				    || arg.startsWith("-flto")
				    || arg.startsWith("-fsanitize=")
				    || arg.startsWith("-gcc=")
				    || arg.startsWith("-link-")
				    || arg.startsWith("-linker=")
				    || arg.startsWith("-march=")
				    || arg.startsWith("-mscrtlib=")
				    || arg.startsWith("-mtriple=");
		}
	}

	protected string[] defaultProbeArgs () const {
		return ["-c", "-o-", "-v"];
	}
}
