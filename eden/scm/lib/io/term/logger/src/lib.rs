/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This software may be used and distributed according to the terms of the
 * GNU General Public License version 2.
 */

use std::io::Write;

use io::IO;
use lazystr::LazyStr;

/// TermLogger mixes the IO object with knowledge of output verbosity.
pub struct TermLogger {
    output: io::IOOutput,
    error: io::IOError,
    quiet: bool,
    verbose: bool,
}

impl TermLogger {
    pub fn new(io: &IO) -> Self {
        TermLogger {
            output: io.output(),
            error: io.error(),
            quiet: false,
            verbose: false,
        }
    }

    pub fn with_quiet(mut self, quiet: bool) -> Self {
        self.quiet = quiet;
        self
    }

    pub fn with_verbose(mut self, verbose: bool) -> Self {
        self.verbose = verbose;
        self
    }

    /// Write to stdout if not --quiet.
    pub fn info(&mut self, msg: impl LazyStr) {
        if !self.quiet {
            Self::write(&mut self.output, msg.to_str())
        }
    }

    /// Write to stderr.
    pub fn warn(&mut self, msg: impl AsRef<str>) {
        Self::write(&mut self.error, msg)
    }

    /// Write to stdout if --verbose.
    pub fn verbose(&mut self, msg: impl LazyStr) {
        if self.verbose {
            Self::write(&mut self.output, msg.to_str())
        }
    }

    /// Short client program name.
    pub fn cli_name(&self) -> &'static str {
        identity::cli_name()
    }

    pub fn flush(&mut self) {
        let _ = self.output.flush();
        let _ = self.error.flush();
    }

    fn write(mut w: impl Write, msg: impl AsRef<str>) {
        let msg = msg.as_ref();

        if let Err(err) = || -> std::io::Result<()> {
            w.write_all(msg.as_bytes())?;
            if !msg.ends_with('\n') {
                w.write_all(b"\n")?;
            }
            Ok(())
        }() {
            tracing::warn!(?msg, ?err, "error writing command output");
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_quiet() {
        let io = IO::new("".as_bytes(), Vec::new(), Some(Vec::new()));
        let mut logger = TermLogger::new(&io).with_quiet(true);
        logger.info("hello");
        logger.warn("error");
        assert_eq!(get_stdout(&io), "");
        assert_eq!(get_stderr(&io), "error\n");
    }

    #[test]
    fn test_default() {
        let io = IO::new("".as_bytes(), Vec::new(), Some(Vec::new()));
        let mut logger = TermLogger::new(&io);
        logger.info("status");
        logger.verbose("verbose");
        logger.warn("warn");
        assert_eq!(get_stdout(&io), "status\n");
        assert_eq!(get_stderr(&io), "warn\n");
    }

    #[test]
    fn test_verbose() {
        let io = IO::new("".as_bytes(), Vec::new(), Some(Vec::new()));
        let mut logger = TermLogger::new(&io);
        logger.verbose(|| -> String {
            panic!("don't call me!");
        });
        assert_eq!(get_stdout(&io), "");

        let mut logger = logger.with_verbose(true);
        logger.verbose(|| "okay".to_string());
        assert_eq!(get_stdout(&io), "okay\n");
    }

    fn get_stdout(io: &IO) -> String {
        let stdout = io.with_output(|o| o.as_any().downcast_ref::<Vec<u8>>().unwrap().clone());
        String::from_utf8(stdout).unwrap()
    }

    fn get_stderr(io: &IO) -> String {
        let stderr = io.with_error(|o| {
            o.unwrap()
                .as_any()
                .downcast_ref::<Vec<u8>>()
                .unwrap()
                .clone()
        });
        String::from_utf8(stderr).unwrap()
    }
}
