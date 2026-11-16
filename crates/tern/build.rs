//! ternd links libghostty-vt statically from the vendored Ghostty build: `zig-out/lib` for this
//! machine, or `zig-out/<target>/lib` when cross-compiling (`scripts/build-ghostty.sh --vt-linux`).

use std::path::PathBuf;

fn main() {
    let out_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../vendor/ghostty/zig-out");
    let target = std::env::var("TARGET").unwrap();
    let host = std::env::var("HOST").unwrap();
    let lib = if target == host { out_root.join("lib") } else { out_root.join(&target).join("lib") }.join("libghostty-vt.a");
    println!("cargo:rerun-if-changed={}", lib.display());
    if !lib.exists() {
        let how = if target == host { "scripts/build-ghostty.sh --vt".to_string() } else { format!("scripts/build-ghostty.sh --vt-linux {}", target.split('-').next().unwrap()) };
        panic!("{} is missing: run {how} first", lib.display());
    }
    // Zig installs the dylib beside it, and the linker would prefer that; search
    // a folder that holds only the static library.
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    std::fs::copy(&lib, out.join("libghostty-vt.a")).expect("copying libghostty-vt.a");
    println!("cargo:rustc-link-search=native={}", out.display());
}
