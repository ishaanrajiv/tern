//! ternd links libghostty-vt statically from the vendored Ghostty build.

use std::path::PathBuf;

fn main() {
    let lib = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../vendor/ghostty/zig-out/lib/libghostty-vt.a");
    println!("cargo:rerun-if-changed={}", lib.display());
    if !lib.exists() {
        panic!("{} is missing: run scripts/build-ghostty.sh first", lib.display());
    }
    // Zig installs the dylib beside it, and the linker would prefer that; search
    // a folder that holds only the static library.
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    std::fs::copy(&lib, out.join("libghostty-vt.a")).expect("copying libghostty-vt.a");
    println!("cargo:rustc-link-search=native={}", out.display());
}
