fn main() {
    let qt_include_path = std::env::var("DEP_QT_INCLUDE_PATH").unwrap();
    let mut config = cpp_build::Config::new();
    for f in std::env::var("DEP_QT_COMPILE_FLAGS")
        .unwrap()
        .split_terminator(';')
    {
        config.flag(f);
    }
    config
        .flag_if_supported("-std=c++17")
        .include(&qt_include_path)
        .build("src/main.rs");
}
