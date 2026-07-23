use std::fmt;

use displaydoc::Display;
use thiserror::Error;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Name(String);

impl Name {
    pub fn parse(input: &str) -> Result<Self, ParseError> {
        let value = input.trim();
        if input != value
            || value.is_empty()
            || matches!(value, "." | "..")
            || value.contains(['/', '\\'])
            || value
                .chars()
                .any(|character| character.is_whitespace() || character.is_control())
        {
            return Err(ParseError::Invalid {
                value: input.to_owned(),
            });
        }
        Ok(Self(value.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Name {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Debug, Display, Eq, Error, PartialEq)]
pub enum ParseError {
    /// deploy key name must be non-empty and contain no whitespace, path separators, or dot traversal: {value}
    Invalid { value: String },
}

#[cfg(test)]
mod test {
    use super::Name;

    #[test]
    fn name_accepts_safe_filename_components() {
        let name = Name::parse("repo.example-key_1").unwrap();
        assert_eq!(name.as_str(), "repo.example-key_1");
    }

    #[test]
    fn name_rejects_paths_whitespace_and_dot_traversal() {
        for value in [
            "",
            " ",
            ".",
            "..",
            "/tmp/key",
            "nested/key",
            "nested\\key",
            "two words",
            " repo-key",
        ] {
            assert!(
                Name::parse(value).is_err(),
                "accepted unsafe key name: {value}"
            );
        }
    }
}
