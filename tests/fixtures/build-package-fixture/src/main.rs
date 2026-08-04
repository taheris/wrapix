fn main() {
    println!("{}", env!("BUILD_RUSTC"));
    println!("{}", env!("BUILD_RUSTC_SYSROOT"));
}

#[cfg(test)]
mod tests {
    #[test]
    fn compiler_metadata_is_embedded() {
        assert!(!env!("BUILD_RUSTC").is_empty());
        assert!(!env!("BUILD_RUSTC_SYSROOT").is_empty());
    }
}
