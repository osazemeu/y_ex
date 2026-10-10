use std::sync::RwLock;
use yrs::{ReadTxn, Store, Transaction, TransactionMut};

pub struct TransactionResource(pub RwLock<Option<TransactionMut<'static>>>);

#[rustler::resource_impl]
impl rustler::Resource for TransactionResource {}

/// Takes the value out of `slot`, releases the lock, then drops it. For a transaction the
/// drop is the commit; if it panics, `slot` already holds `None`, so the resource's
/// destructor cannot drop the same transaction a second time.
pub fn take_then_drop<T>(slot: &RwLock<Option<T>>) {
    let value = slot.write().unwrap_or_else(|e| e.into_inner()).take();
    drop(value);
}

pub enum ReadTransaction<'a, 'doc> {
    ReadOnly(&'a Transaction<'doc>),
    ReadWrite(&'a TransactionMut<'doc>),
}

impl ReadTxn for ReadTransaction<'_, '_> {
    fn store(&self) -> &Store {
        match &self {
            ReadTransaction::ReadOnly(txn) => txn.store(),
            ReadTransaction::ReadWrite(txn) => txn.store(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::take_then_drop;
    use std::panic::{catch_unwind, AssertUnwindSafe};
    use std::sync::RwLock;

    struct PanicOnDrop;

    impl Drop for PanicOnDrop {
        fn drop(&mut self) {
            panic!("commit failed");
        }
    }

    #[test]
    fn take_then_drop_leaves_none_when_the_drop_panics() {
        let slot = RwLock::new(Some(PanicOnDrop));
        let result = catch_unwind(AssertUnwindSafe(|| take_then_drop(&slot)));
        assert!(result.is_err());
        assert!(!slot.is_poisoned());
        assert!(slot.read().unwrap().is_none());
    }
}
