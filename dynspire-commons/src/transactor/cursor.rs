use std::cell::RefCell;
use std::sync::Arc;

pub trait Cursor: Send {
    fn is_valid(&self) -> bool;
    fn current_key(&self) -> Option<&[u8]>;
    fn step(&mut self);
    fn skip_group(&mut self, group_end: usize);
    fn seek(&mut self, target: &[u8]);
    fn update_end(&mut self, end: &[u8]);
    fn invalidate(&mut self);
}

#[derive(Clone)]
pub struct CursorHandle {
    pub cursor: Arc<RefCell<dyn Cursor>>,
}

struct InvalidCursor;

impl Cursor for InvalidCursor {
    fn is_valid(&self) -> bool { false }
    fn current_key(&self) -> Option<&[u8]> { None }
    fn step(&mut self) {}
    fn skip_group(&mut self, _: usize) {}
    fn seek(&mut self, _: &[u8]) {}
    fn update_end(&mut self, _: &[u8]) {}
    fn invalidate(&mut self) {}
}

pub fn invalid_cursor_handle() -> CursorHandle {
    CursorHandle {
        cursor: Arc::new(RefCell::new(InvalidCursor)),
    }
}
