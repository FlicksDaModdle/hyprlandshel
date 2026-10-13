fn main() {
    let kit = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../kit/ui/kit.slint");
    let config = slint_build::CompilerConfiguration::new()
        .with_style("fluent".into())
        .with_library_paths(std::collections::HashMap::from([("kit".to_string(), kit)]));
    slint_build::compile_with_config("ui/app.slint", config).unwrap();
}
