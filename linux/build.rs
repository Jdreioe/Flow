fn main() {
    cpp_build::Config::new()
        .flag_if_supported("-std=c++17")
        .build("src/main.rs");
}
