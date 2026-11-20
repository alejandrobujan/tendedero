fn main() {
    println!("cargo:rerun-if-changed=resources/app.rc");
    println!("cargo:rerun-if-changed=resources/app.manifest");
    println!("cargo:rerun-if-changed=assets/tendedero.ico");
    embed_resource::compile("resources/app.rc", embed_resource::NONE)
        .manifest_optional()
        .expect("embedding the icon and manifest failed");
}
