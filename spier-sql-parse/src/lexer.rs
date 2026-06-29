#[allow(non_camel_case_types)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TT {
    SELECT,
    WHERE,
    AND,
    OR,
    IN,
    UPSERT,
    AS,
    SET,
    DELETE,
    UPDATE,
    FROM,
    ATTRIBUTE,
    MANY,
    ONE,
    REF,
    BYTES,
    EXPLAIN,
    DATALOG,
    UNIQUE,
    PARTITION,
    HISTORY,
    STAR,
    DOT,
    COMMA,
    LPAREN,
    RPAREN,
    EQ,
    GT,
    LT,
    GTE,
    LTE,
    NEQ,
    INTEGER,
    FLOAT,
    STRING,
    ALIAS,
    IDENT,
    PARAM,
    EOF,
}

pub static TT_NAMES: &[&str] = &[
    "SELECT", "WHERE", "AND", "OR", "IN", "UPSERT", "AS", "SET",
    "DELETE", "UPDATE", "FROM",
    "ATTRIBUTE", "MANY", "ONE", "REF", "BYTES", "EXPLAIN", "DATALOG", "UNIQUE", "PARTITION",
    "HISTORY",
    "STAR", "DOT", "COMMA", "LPAREN", "RPAREN", "EQ", "GT", "LT", "GTE", "LTE", "NEQ",
    "INTEGER", "FLOAT", "STRING", "ALIAS", "IDENT", "PARAM", "EOF",
];

fn keyword_tt(word: &str) -> Option<TT> {
    Some(match word {
        "SELECT" => TT::SELECT,
        "WHERE" => TT::WHERE,
        "AND" => TT::AND,
        "UPSERT" => TT::UPSERT,
        "AS" => TT::AS,
        "SET" => TT::SET,
        "DELETE" => TT::DELETE,
        "UPDATE" => TT::UPDATE,
        "FROM" => TT::FROM,
        "ATTRIBUTE" => TT::ATTRIBUTE,
        "MANY" => TT::MANY,
        "ONE" => TT::ONE,
        "REF" => TT::REF,
        "BYTES" => TT::BYTES,
        "EXPLAIN" => TT::EXPLAIN,
        "DATALOG" => TT::DATALOG,
        "OR" => TT::OR,
        "UNIQUE" => TT::UNIQUE,
        "IN" => TT::IN,
        "PARTITION" => TT::PARTITION,
        "HISTORY" => TT::HISTORY,
        _ => return None,
    })
}

#[derive(Debug)]
pub struct LexToken {
    pub tt: TT,
    pub value: String,
    pub pos: usize,
}

#[derive(Debug)]
pub struct LexErr {
    pub message: String,
    pub pos: usize,
}

impl std::fmt::Display for LexErr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} at position {}", self.message, self.pos)
    }
}

struct Lexer<'a> {
    src: &'a str,
    pos: usize,
    len: usize,
}

impl<'a> Lexer<'a> {
    fn new(src: &'a str) -> Self {
        Self {
            src,
            pos: 0,
            len: src.len(),
        }
    }

    fn skip_whitespace(&mut self) {
        let bytes = self.src.as_bytes();
        while self.pos < self.len {
            match bytes[self.pos] {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn read_param(&mut self) -> Result<LexToken, LexErr> {
        let start = self.pos;
        let bytes = self.src.as_bytes();
        self.pos += 1;
        if self.pos >= self.len || !bytes[self.pos].is_ascii_digit() {
            return Err(LexErr {
                message: "expected digit after '%'".into(),
                pos: self.pos,
            });
        }
        while self.pos < self.len && bytes[self.pos].is_ascii_digit() {
            self.pos += 1;
        }
        Ok(LexToken {
            tt: TT::PARAM,
            value: self.src[start..self.pos].into(),
            pos: start,
        })
    }

    fn read_string(&mut self) -> Result<LexToken, LexErr> {
        let start = self.pos;
        let bytes = self.src.as_bytes();
        self.pos += 1;
        let mut parts = String::new();
        while self.pos < self.len {
            let ch = bytes[self.pos] as char;
            if ch == '\'' {
                if self.pos + 1 < self.len && bytes[self.pos + 1] == b'\'' {
                    parts.push('\'');
                    self.pos += 2;
                } else {
                    self.pos += 1;
                    return Ok(LexToken {
                        tt: TT::STRING,
                        value: parts,
                        pos: start,
                    });
                }
            } else {
                parts.push(ch);
                self.pos += 1;
            }
        }
        Err(LexErr {
            message: "unterminated string literal".into(),
            pos: start,
        })
    }

    fn read_number(&mut self) -> LexToken {
        let start = self.pos;
        let bytes = self.src.as_bytes();
        if bytes[self.pos] == b'-' {
            self.pos += 1;
        }
        while self.pos < self.len && bytes[self.pos].is_ascii_digit() {
            self.pos += 1;
        }
        if self.pos < self.len && bytes[self.pos] == b'.' {
            self.pos += 1;
            while self.pos < self.len && bytes[self.pos].is_ascii_digit() {
                self.pos += 1;
            }
            LexToken {
                tt: TT::FLOAT,
                value: self.src[start..self.pos].into(),
                pos: start,
            }
        } else {
            LexToken {
                tt: TT::INTEGER,
                value: self.src[start..self.pos].into(),
                pos: start,
            }
        }
    }

    fn read_ident_or_keyword(&mut self) -> LexToken {
        let start = self.pos;
        let bytes = self.src.as_bytes();
        while self.pos < self.len {
            let b = bytes[self.pos];
            if b.is_ascii_alphanumeric() || b == b'_' || b == b':' || b == b'/' || b == b'-' {
                self.pos += 1;
            } else {
                break;
            }
        }
        let word = &self.src[start..self.pos];
        if let Some(tt) = keyword_tt(&word.to_uppercase()) {
            LexToken {
                tt,
                value: word.into(),
                pos: start,
            }
        } else if word.starts_with('d')
            && word.len() >= 2
            && word[1..].bytes().all(|b| b.is_ascii_digit())
        {
            LexToken {
                tt: TT::ALIAS,
                value: word.into(),
                pos: start,
            }
        } else {
            LexToken {
                tt: TT::IDENT,
                value: word.into(),
                pos: start,
            }
        }
    }

    fn run(&mut self) -> Result<Vec<LexToken>, LexErr> {
        let mut tokens = Vec::new();
        let bytes = self.src.as_bytes();
        while self.pos < self.len {
            self.skip_whitespace();
            if self.pos >= self.len {
                break;
            }
            let b = bytes[self.pos];
            match b {
                b'*' => {
                    tokens.push(LexToken {
                        tt: TT::STAR,
                        value: "*".into(),
                        pos: self.pos,
                    });
                    self.pos += 1;
                }
                b'.' => {
                    tokens.push(LexToken {
                        tt: TT::DOT,
                        value: ".".into(),
                        pos: self.pos,
                    });
                    self.pos += 1;
                }
                b',' => {
                    tokens.push(LexToken {
                        tt: TT::COMMA,
                        value: ",".into(),
                        pos: self.pos,
                    });
                    self.pos += 1;
                }
                b'(' => {
                    tokens.push(LexToken {
                        tt: TT::LPAREN,
                        value: "(".into(),
                        pos: self.pos,
                    });
                    self.pos += 1;
                }
                b')' => {
                    tokens.push(LexToken {
                        tt: TT::RPAREN,
                        value: ")".into(),
                        pos: self.pos,
                    });
                    self.pos += 1;
                }
                b'!' if self.pos + 1 < self.len && bytes[self.pos + 1] == b'=' => {
                    tokens.push(LexToken {
                        tt: TT::NEQ,
                        value: "!=".into(),
                        pos: self.pos,
                    });
                    self.pos += 2;
                }
                b'=' => {
                    tokens.push(LexToken {
                        tt: TT::EQ,
                        value: "=".into(),
                        pos: self.pos,
                    });
                    self.pos += 1;
                }
                b'>' if self.pos + 1 < self.len && bytes[self.pos + 1] == b'=' => {
                    tokens.push(LexToken {
                        tt: TT::GTE,
                        value: ">=".into(),
                        pos: self.pos,
                    });
                    self.pos += 2;
                }
                b'>' => {
                    tokens.push(LexToken {
                        tt: TT::GT,
                        value: ">".into(),
                        pos: self.pos,
                    });
                    self.pos += 1;
                }
                b'<' if self.pos + 1 < self.len && bytes[self.pos + 1] == b'>' => {
                    tokens.push(LexToken {
                        tt: TT::NEQ,
                        value: "<>".into(),
                        pos: self.pos,
                    });
                    self.pos += 2;
                }
                b'<' if self.pos + 1 < self.len && bytes[self.pos + 1] == b'=' => {
                    tokens.push(LexToken {
                        tt: TT::LTE,
                        value: "<=".into(),
                        pos: self.pos,
                    });
                    self.pos += 2;
                }
                b'<' => {
                    tokens.push(LexToken {
                        tt: TT::LT,
                        value: "<".into(),
                        pos: self.pos,
                    });
                    self.pos += 1;
                }
                b'%' => {
                    tokens.push(self.read_param()?);
                }
                b'\'' => {
                    tokens.push(self.read_string()?);
                }
                b'0'..=b'9' => {
                    tokens.push(self.read_number());
                }
                b'-' if self.pos + 1 < self.len && bytes[self.pos + 1].is_ascii_digit() => {
                    tokens.push(self.read_number());
                }
                b':' | b'_' | b'a'..=b'z' | b'A'..=b'Z' => {
                    tokens.push(self.read_ident_or_keyword());
                }
                _ => {
                    return Err(LexErr {
                        message: format!("unexpected character '{}'", b as char),
                        pos: self.pos,
                    });
                }
            }
        }
        tokens.push(LexToken {
            tt: TT::EOF,
            value: String::new(),
            pos: self.pos,
        });
        Ok(tokens)
    }
}

pub fn tokenize(source: &str) -> Result<Vec<LexToken>, LexErr> {
    Lexer::new(source).run()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ttypes(src: &str) -> Vec<TT> {
        tokenize(src).unwrap().iter().map(|t| t.tt).collect()
    }

    fn tokens(src: &str) -> Vec<LexToken> {
        tokenize(src).unwrap()
    }

    #[test]
    fn simple_select() {
        let types = ttypes("SELECT d1.eid WHERE d1.eid = %1");
        assert_eq!(&types[..types.len()-1], &[
            TT::SELECT,
            TT::ALIAS, TT::DOT, TT::IDENT,
            TT::WHERE,
            TT::ALIAS, TT::DOT, TT::IDENT,
            TT::EQ,
            TT::PARAM,
        ]);
    }

    #[test]
    fn multiple_aliases() {
        let types = ttypes("SELECT d2.name WHERE d1.partner = d2.eid");
        assert_eq!(&types[..types.len()-1], &[
            TT::SELECT,
            TT::ALIAS, TT::DOT, TT::IDENT,
            TT::WHERE,
            TT::ALIAS, TT::DOT, TT::IDENT,
            TT::EQ,
            TT::ALIAS, TT::DOT, TT::IDENT,
        ]);
    }

    #[test]
    fn range_operators() {
        let types = ttypes("WHERE d1.price > %1 AND d1.price <= %2");
        assert!(types.contains(&TT::GT));
        assert!(types.contains(&TT::LTE));
    }

    #[test]
    fn gte_lt_operators() {
        let types = ttypes("WHERE d1.x >= %1 AND d1.y < %2");
        assert!(types.contains(&TT::GTE));
        assert!(types.contains(&TT::LT));
    }

    #[test]
    fn string_literal() {
        let toks = tokens("WHERE d1.name = 'hello world'");
        let s = toks.iter().find(|t| t.tt == TT::STRING).unwrap();
        assert_eq!(s.value, "hello world");
    }

    #[test]
    fn string_with_escaped_quote() {
        let toks = tokens("WHERE d1.name = 'it''s fine'");
        let s = toks.iter().find(|t| t.tt == TT::STRING).unwrap();
        assert_eq!(s.value, "it's fine");
    }

    #[test]
    fn integer_literal() {
        let toks = tokens("WHERE d1.price > 1000");
        let n = toks.iter().find(|t| t.tt == TT::INTEGER).unwrap();
        assert_eq!(n.value, "1000");
    }

    #[test]
    fn float_literal() {
        let toks = tokens("WHERE d1.price > 3.14");
        let f = toks.iter().find(|t| t.tt == TT::FLOAT).unwrap();
        assert_eq!(f.value, "3.14");
    }

    #[test]
    fn negative_number() {
        let toks = tokens("WHERE d1.temp > -5");
        let n = toks.iter().filter(|t| t.tt == TT::INTEGER).last().unwrap();
        assert_eq!(n.value, "-5");
    }

    #[test]
    fn param_values() {
        let toks = tokens("WHERE d1.eid = %1 AND d2.val = %42");
        let params: Vec<&LexToken> = toks.iter().filter(|t| t.tt == TT::PARAM).collect();
        assert_eq!(params[0].value, "%1");
        assert_eq!(params[1].value, "%42");
    }

    #[test]
    fn select_literal_integer() {
        let toks = tokens("SELECT 1 WHERE d1.eid = %1");
        assert_eq!(toks[1].tt, TT::INTEGER);
        assert_eq!(toks[1].value, "1");
    }

    #[test]
    fn comma_separated_projections() {
        let toks = tokens("SELECT d1.eid, d1.name, d1.tx WHERE d1.eid = %1");
        let commas: Vec<&LexToken> = toks.iter().filter(|t| t.tt == TT::COMMA).collect();
        assert_eq!(commas.len(), 2);
    }

    #[test]
    fn eof_token() {
        let toks = tokens("SELECT d1.eid");
        assert_eq!(toks.last().unwrap().tt, TT::EOF);
    }

    #[test]
    fn keyword_case_insensitive() {
        let toks = tokens("select d1.eid where d1.eid = %1");
        assert_eq!(toks[0].tt, TT::SELECT);
        assert_eq!(toks[4].tt, TT::WHERE);
    }

    #[test]
    fn alias_format() {
        let toks = tokens("SELECT d1.eid, d10.name, d99.val");
        let aliases: Vec<&LexToken> = toks.iter().filter(|t| t.tt == TT::ALIAS).collect();
        assert_eq!(aliases[0].value, "d1");
        assert_eq!(aliases[1].value, "d10");
        assert_eq!(aliases[2].value, "d99");
    }

    #[test]
    fn token_positions() {
        let toks = tokens("SELECT d1.eid");
        assert_eq!(toks[0].pos, 0);
        assert_eq!(toks[1].pos, 7);
        assert_eq!(toks[2].pos, 9);
        assert_eq!(toks[3].pos, 10);
    }

    #[test]
    fn whitespace_skipped() {
        let toks = tokens("  SELECT   d1.eid  WHERE  d1.eid = %1  ");
        assert_eq!(toks[0].tt, TT::SELECT);
        assert_eq!(toks.last().unwrap().tt, TT::EOF);
    }

    #[test]
    fn delete_keyword() {
        let types = ttypes("DELETE WHERE");
        assert_eq!(&types[..types.len()-1], &[TT::DELETE, TT::WHERE]);
    }

    #[test]
    fn parentheses() {
        let types = ttypes("ref(%1)");
        assert_eq!(&types[..types.len()-1], &[
            TT::REF, TT::LPAREN, TT::PARAM, TT::RPAREN,
        ]);
    }

    #[test]
    fn hyphenated_attribute() {
        let toks = tokens("SELECT d1.my-attr");
        let idents: Vec<&LexToken> = toks.iter().filter(|t| t.tt == TT::IDENT).collect();
        assert_eq!(idents[0].value, "my-attr");
    }

    #[test]
    fn error_unexpected_character() {
        let err = tokenize("SELECT d1.eid # comment").unwrap_err();
        assert!(err.message.contains("unexpected character"));
    }

    #[test]
    fn error_unterminated_string() {
        let err = tokenize("WHERE d1.name = 'unterminated").unwrap_err();
        assert!(err.message.contains("unterminated string"));
    }

    #[test]
    fn error_param_without_digit() {
        let err = tokenize("WHERE d1.eid = %").unwrap_err();
        assert!(err.message.contains("expected digit"));
    }

    #[test]
    fn tt_names_complete() {
        assert_eq!(TT_NAMES.len(), 39);
        assert_eq!(TT_NAMES[TT::SELECT as usize], "SELECT");
        assert_eq!(TT_NAMES[TT::WHERE as usize], "WHERE");
        assert_eq!(TT_NAMES[TT::EOF as usize], "EOF");
    }
}
