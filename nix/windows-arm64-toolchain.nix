{ pkgs }:
let
	# Keep the pinned provider and compiler. These narrow corrections repair
	# its MinGW LLVM bootstrap without changing the native Linux toolchain.
	target = (import pkgs.path {
		system = pkgs.stdenv.buildPlatform.system;
		overlays = [ (_: previous: {
			windows = previous.windows.overrideScope (_: windowsPrevious: {
				pthreads = if windowsPrevious.pthreads.stdenv.hostPlatform.isAarch64 then
					windowsPrevious.pthreads.overrideAttrs (old: {
						makeFlags = (old.makeFlags or []) ++ [ "RCFLAGS=-I${windowsPrevious.mingw_w64_headers}/include" ];
					}) else windowsPrevious.pthreads;
			});
			llvmPackages_21 = previous.llvmPackages_21.overrideScope (_: llvmPrevious: let
				windowsArm = drv: drv.stdenv.hostPlatform.isWindows && drv.stdenv.hostPlatform.isAarch64;
				staticAtomics = drv: if windowsArm drv then drv.override {
					# Match llvm-mingw: retain atomic builtins in the static runtime,
					# without trying to link a standalone DLL before the CRT exists.
					withAtomics = false;
					devExtraCmakeFlags = [ "-DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN:BOOL=FALSE" ];
				} else drv;
			in {
				compiler-rt-no-libc = staticAtomics llvmPrevious.compiler-rt-no-libc;
				compiler-rt-libc = staticAtomics llvmPrevious.compiler-rt-libc;
				# Preserve Rust panic unwinding while removing libunwind.dll from
				# the standalone executable and external C consumer's imports.
				libunwind = if windowsArm llvmPrevious.libunwind then
					llvmPrevious.libunwind.override { enableShared = false; doFakeLibgcc = false; }
					else llvmPrevious.libunwind;
			});
		}) ];
	}).pkgsCross.ucrtAarch64;
in target // { buildPackages = pkgs; }
