use crate::ast::SExpr;

#[derive(Debug, Clone, PartialEq)]
pub struct ParseError {
    pub pos: usize,
    pub msg: String,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "parse error at {}: {}", self.pos, self.msg)
    }
}

fn is_delimiter(c: u8) -> bool {
    c.is_ascii_whitespace() || c == b'(' || c == b')' || c == b'"' || c == b';'
}

pub fn parse(input: &str) -> Result<SExpr, ParseError> {
    let mut p = Parser::new(input);
    p.skip_whitespace_and_comments();
    if p.is_at_end() {
        return Err(ParseError {
            pos: p.pos,
            msg: "empty input".into(),
        });
    }
    let expr = p.parse_expr()?;
    p.skip_whitespace_and_comments();
    if !p.is_at_end() {
        return Err(ParseError {
            pos: p.pos,
            msg: format!("unexpected trailing input: {:?}", p.remaining()),
        });
    }
    Ok(expr)
}

struct Parser<'a> {
    src: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn new(src: &'a str) -> Self {
        Self {
            src: src.as_bytes(),
            pos: 0,
        }
    }

    fn is_at_end(&self) -> bool {
        self.pos >= self.src.len()
    }

    fn remaining(&self) -> &str {
        std::str::from_utf8(&self.src[self.pos..]).unwrap_or("?")
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn advance(&mut self) -> Option<u8> {
        let b = self.src.get(self.pos).copied()?;
        self.pos += 1;
        Some(b)
    }

    fn skip_whitespace_and_comments(&mut self) {
        loop {
            match self.peek() {
                Some(b) if b.is_ascii_whitespace() => {
                    self.advance();
                }
                Some(b';') => {
                    while let Some(b) = self.peek() {
                        self.advance();
                        if b == b'\n' {
                            break;
                        }
                    }
                }
                _ => break,
            }
        }
    }

    fn parse_expr(&mut self) -> Result<SExpr, ParseError> {
        self.skip_whitespace_and_comments();
        match self.peek() {
            Some(b'(') => self.parse_list(),
            Some(b'"') => self.parse_string(),
            Some(b'#') => self.parse_bool_or_hash(),
            Some(b) if b.is_ascii_digit() || b == b'-' => self.parse_number_or_symbol(),
            _ => self.parse_symbol(),
        }
    }

    fn parse_list(&mut self) -> Result<SExpr, ParseError> {
        let open_pos = self.pos;
        self.advance(); // consume '('
        let mut items = Vec::new();
        loop {
            self.skip_whitespace_and_comments();
            match self.peek() {
                Some(b')') => {
                    self.advance();
                    return Ok(SExpr::List(items));
                }
                None => {
                    return Err(ParseError {
                        pos: open_pos,
                        msg: "unterminated list".into(),
                    });
                }
                _ => {
                    items.push(self.parse_expr()?);
                }
            }
        }
    }

    fn parse_string(&mut self) -> Result<SExpr, ParseError> {
        let start = self.pos;
        self.advance(); // consume opening "
        let mut s = String::new();
        loop {
            match self.advance() {
                Some(b'"') => return Ok(SExpr::Str(s)),
                Some(b'\\') => match self.advance() {
                    Some(b'n') => s.push('\n'),
                    Some(b't') => s.push('\t'),
                    Some(b'\\') => s.push('\\'),
                    Some(b'"') => s.push('"'),
                    Some(c) => {
                        s.push('\\');
                        s.push(c as char);
                    }
                    None => {
                        return Err(ParseError {
                            pos: start,
                            msg: "unterminated escape in string".into(),
                        });
                    }
                },
                Some(c) => s.push(c as char),
                None => {
                    return Err(ParseError {
                        pos: start,
                        msg: "unterminated string".into(),
                    });
                }
            }
        }
    }

    fn parse_bool_or_hash(&mut self) -> Result<SExpr, ParseError> {
        let start = self.pos;
        self.advance(); // consume #
        match self.peek() {
            Some(b't') => {
                self.advance();
                Ok(SExpr::Bool(true))
            }
            Some(b'f') => {
                self.advance();
                Ok(SExpr::Bool(false))
            }
            _ => Err(ParseError {
                pos: start,
                msg: "expected 't' or 'f' after #".into(),
            }),
        }
    }

    fn parse_number_or_symbol(&mut self) -> Result<SExpr, ParseError> {
        let start = self.pos;
        let has_leading_minus = self.peek() == Some(b'-');
        if has_leading_minus {
            self.advance();
        }

        let digit_start = self.pos;
        while self.peek().map_or(false, |c| c.is_ascii_digit()) {
            self.advance();
        }

        if self.pos == digit_start {
            self.pos = start;
            return self.parse_symbol_rest();
        }

        let has_dot = self.peek() == Some(b'.')
            && self.src.get(self.pos + 1).map_or(false, |c| c.is_ascii_digit());
        if has_dot {
            self.advance();
            while self.peek().map_or(false, |c| c.is_ascii_digit()) {
                self.advance();
            }
        }

        if !self.is_at_end() && !self.peek().map_or(true, is_delimiter) {
            self.pos = start;
            return self.parse_symbol_rest();
        }

        let tok = std::str::from_utf8(&self.src[start..self.pos])
            .map_err(|_| ParseError { pos: start, msg: "invalid UTF-8".into() })?;

        if has_dot {
            if let Ok(v) = tok.parse::<f64>() {
                return Ok(SExpr::Float(v));
            }
        } else if let Ok(v) = tok.parse::<i64>() {
            return Ok(SExpr::Int(v));
        }

        Ok(SExpr::Symbol(tok.to_string()))
    }

    fn parse_symbol_rest(&mut self) -> Result<SExpr, ParseError> {
        let start = self.pos;
        while let Some(c) = self.peek() {
            if c.is_ascii_whitespace() || c == b'(' || c == b')' || c == b'"' || c == b';' {
                break;
            }
            self.advance();
        }
        let tok = std::str::from_utf8(&self.src[start..self.pos])
            .map_err(|_| ParseError {
                pos: start,
                msg: "invalid UTF-8".into(),
            })?;
        Ok(SExpr::Symbol(tok.to_string()))
    }

    fn parse_symbol(&mut self) -> Result<SExpr, ParseError> {
        self.skip_whitespace_and_comments();
        self.parse_symbol_rest()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atoms() {
        assert_eq!(parse("42").unwrap(), SExpr::Int(42));
        assert_eq!(parse("-7").unwrap(), SExpr::Int(-7));
        assert_eq!(parse("3.14").unwrap(), SExpr::Float(3.14));
        assert_eq!(parse("#t").unwrap(), SExpr::Bool(true));
        assert_eq!(parse("#f").unwrap(), SExpr::Bool(false));
        assert_eq!(parse("\"hello\"").unwrap(), SExpr::Str("hello".into()));
        assert_eq!(
            parse("\"line\\none\"").unwrap(),
            SExpr::Str("line\none".into())
        );
        assert_eq!(parse("foo").unwrap(), SExpr::Symbol("foo".into()));
    }

    #[test]
    fn lists() {
        assert_eq!(parse("()").unwrap(), SExpr::List(vec![]));
        assert_eq!(
            parse("(1 2 3)").unwrap(),
            SExpr::List(vec![SExpr::Int(1), SExpr::Int(2), SExpr::Int(3)])
        );
        assert_eq!(
            parse("(+ 1 (* 2 3))").unwrap(),
            SExpr::List(vec![
                SExpr::Symbol("+".into()),
                SExpr::Int(1),
                SExpr::List(vec![
                    SExpr::Symbol("*".into()),
                    SExpr::Int(2),
                    SExpr::Int(3),
                ]),
            ])
        );
    }

    #[test]
    fn comments_and_whitespace() {
        assert_eq!(
            parse("( 1 ; comment\n 2 )").unwrap(),
            SExpr::List(vec![SExpr::Int(1), SExpr::Int(2)])
        );
    }

    #[test]
    fn errors() {
        assert!(parse("(").is_err());
        assert!(parse("\"unterminated").is_err());
        assert!(parse("").is_err());
    }

    #[test]
    fn symbol_with_special_chars() {
        assert_eq!(parse("-1..2").unwrap(), SExpr::Symbol("-1..2".into()));
        assert_eq!(parse("company.name").unwrap(), SExpr::Symbol("company.name".into()));
    }
}
