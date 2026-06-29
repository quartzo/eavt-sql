#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub enum RustLiteral {
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    Bytes(Vec<u8>),
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub enum RustValue {
    Literal(RustLiteral),
    Param(u32),
    AliasRef(String),
    EidLookup {
        attr: Box<RustValue>,
        value: Box<RustValue>,
    },
    ValLookup {
        entity: Box<RustValue>,
        attr: Box<RustValue>,
    },
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RustFieldRef {
    pub alias: String,
    pub field: String,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustProjection {
    pub field: Option<RustFieldRef>,
    pub literal: Option<RustLiteral>,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustOrBranchItem {
    pub left: RustFieldRef,
    pub op: String,
    pub value: RustConditionRight,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub enum RustConditionRight {
    Field(RustFieldRef),
    Literal(RustLiteral),
    Param(u32),
    In(Vec<RustConditionRight>),
    Or(Vec<Vec<RustOrBranchItem>>),
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustCondition {
    pub left: RustFieldRef,
    pub op: String,
    pub right: RustConditionRight,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustInsertValue {
    pub attr: String,
    pub value: RustValue,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustSelectStmt {
    pub projections: Vec<RustProjection>,
    pub conditions: Vec<RustCondition>,
    pub exists_mode: bool,
    pub star: bool,
    pub history: bool,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustDeleteWhereStmt {
    pub conditions: Vec<RustCondition>,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustAttributeStmt {
    pub attr: String,
    pub value_type: String,
    pub many: bool,
    pub unique: bool,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustPartitionStmt {
    pub name: String,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub enum RustStmt {
    Select(RustSelectStmt),
    DatalogSelect(RustSelectStmt),
    Upsert(RustUpsertStmt),
    Update(RustUpdateStmt),
    Delete(RustDeleteWhereStmt),
    Attribute(RustAttributeStmt),
    Partition(RustPartitionStmt),
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub enum UpsertEntityRef {
    New,
    Lookup {
        attr: Box<RustValue>,
        value: Box<RustValue>,
    },
    ExplicitEid(u32),
    Tx,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustUpsertClause {
    pub alias: Option<String>,
    pub entity_ref: UpsertEntityRef,
    pub values: Vec<RustInsertValue>,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustUpsertStmt {
    pub clauses: Vec<RustUpsertClause>,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustUpdateClause {
    pub alias: String,
    pub values: Vec<RustInsertValue>,
}

#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct RustUpdateStmt {
    pub clauses: Vec<RustUpdateClause>,
    pub conditions: Vec<RustCondition>,
}
