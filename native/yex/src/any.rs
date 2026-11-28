use std::cell::Cell;
use std::collections::HashMap;
use std::sync::Arc;

use crate::error::ArgumentError;

use crate::wrap::{make_list, make_map, NifStr, NifWrap};
use rustler::dynamic::TermType;
use rustler::types;
use rustler::{
    Binary, Decoder, Encoder, Env, Error, ListIterator, MapIterator, NewBinary, NifResult,
    NifStruct, Term,
};
use yrs::*;

/// `%Yex.Buffer{data: bytes}`: how a buffer reads back, and how bytes are written as one
/// whatever they contain. Strings are binaries too, so a bare binary can only be guessed
/// at (a string when it is valid UTF-8, a buffer otherwise); the struct says which is meant
/// and keeps a value that is read and written again a buffer.
#[derive(NifStruct)]
#[module = "Yex.Buffer"]
struct NifBuffer<'a> {
    data: Binary<'a>,
}

impl<'a> NifBuffer<'a> {
    fn from_slice(env: Env<'a>, bytes: &[u8]) -> Self {
        let mut data = NewBinary::new(env, bytes.len());
        data.as_mut_slice().copy_from_slice(bytes);
        NifBuffer { data: data.into() }
    }
}

pub(crate) fn encode<'a>(env: Env<'a>, any: &Any) -> Term<'a> {
    match any {
        Any::Null => types::atom::nil().to_term(env),
        Any::Undefined => types::atom::undefined().to_term(env),
        Any::Bool(b) => b.encode(env),
        Any::Number(Number::Float(f)) => f.encode(env),
        // Integers within the safe range are exposed as floats, matching how Yjs treats numbers.
        Any::Number(Number::Int(n))
            if (Number::I64_MIN_SAFE_INTEGER..=Number::I64_MAX_SAFE_INTEGER).contains(n) =>
        {
            (*n as f64).encode(env)
        }
        Any::Number(Number::Int(n)) => n.encode(env),
        Any::String(s) => encode_str(env, s),
        Any::Buffer(b) => encode_buffer(env, b),
        Any::Array(a) => encode_list(env, a),
        Any::Map(m) => encode_nested_map(env, m),
    }
}

// Nested values recurse through `encode`, so it is kept to a small stack frame: the buffer,
// list and map branches are out of line, and only a value of that kind pays for their
// frames. Dirty schedulers have small stacks, and each nesting level costs one of each.
#[inline(never)]
fn encode_buffer<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    NifBuffer::from_slice(env, bytes).encode(env)
}

#[inline(never)]
fn encode_list<'a>(env: Env<'a>, items: &[Any]) -> Term<'a> {
    make_list(env, items.iter().map(|item| encode(env, item)))
}

#[inline(never)]
fn encode_nested_map<'a>(env: Env<'a>, map: &HashMap<String, Any>) -> Term<'a> {
    encode_map(env, map.iter())
}

pub(crate) fn encode_str<'a>(env: Env<'a>, s: &str) -> Term<'a> {
    NifStr(s).encode(env)
}

/// Builds the map straight from term arrays; the keys come from a map, so they are unique.
pub(crate) fn encode_map<'a, 'b, K: AsRef<str> + 'b>(
    env: Env<'a>,
    entries: impl Iterator<Item = (&'b K, &'b Any)>,
) -> Term<'a> {
    make_map(
        env,
        entries.map(|(k, v)| (encode_str(env, k.as_ref()), encode(env, v))),
    )
}
impl rustler::Encoder for NifAny {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        encode(env, &self.0)
    }
}
/// The deepest a term may nest when it is decoded into an [Any] or a prelim: every prelim
/// level ([NifYInput](crate::yinput::NifYInput) holding a prelim, and
/// [NifXmlIn](crate::yinput::NifXmlIn)) and every list or map of an `Any` counts one. Decoding, integration, encoding and yrs
/// recurse once per level on the scheduler's stack, so an unbounded term (a few kilobytes of
/// nested maps) overflows it and kills the VM. It is yrs' own `Any` cap, so anything written
/// here also decodes from the doc's state, and it sits inside yrs' shared-type cap (128).
pub(crate) const MAX_DECODE_DEPTH: usize = yrs::Any::MAX_DEPTH;

thread_local! {
    static DECODE_DEPTH: Cell<usize> = const { Cell::new(0) };
    // Set when a level was refused, so a decoder that tries alternatives (`NifYInput`,
    // `NifXmlIn`) reports the refusal instead of reading it as "not this variant".
    static DECODE_TOO_DEEP: Cell<bool> = const { Cell::new(false) };
    // How many such decoders are running on this thread; the flag lives as long as the
    // outermost one.
    static DECODE_SCOPES: Cell<usize> = const { Cell::new(0) };
}

/// One level of nesting held while a nested term decodes.
pub(crate) struct DepthGuard(());

impl DepthGuard {
    pub(crate) fn enter() -> NifResult<DepthGuard> {
        let depth = DECODE_DEPTH.with(Cell::get);
        if depth >= MAX_DECODE_DEPTH {
            DECODE_TOO_DEEP.with(|flag| flag.set(true));
            return Err(too_deep());
        }
        DECODE_DEPTH.with(|cell| cell.set(depth + 1));
        Ok(DepthGuard(()))
    }
}

impl Drop for DepthGuard {
    fn drop(&mut self) {
        DECODE_DEPTH.with(|cell| cell.set(cell.get() - 1));
    }
}

/// Held by a decoder that tries alternatives. The outermost one starts and ends with the
/// refusal flag clear, so a refusal never leaks into another decode or NIF call.
pub(crate) struct DecodeScope(());

impl DecodeScope {
    pub(crate) fn enter() -> DecodeScope {
        let scopes = DECODE_SCOPES.with(Cell::get);
        if scopes == 0 {
            DECODE_TOO_DEEP.with(|flag| flag.set(false));
        }
        DECODE_SCOPES.with(|cell| cell.set(scopes + 1));
        DecodeScope(())
    }

    /// The refusal error, when a nested decode inside this scope was refused.
    pub(crate) fn refused(&self) -> NifResult<()> {
        if DECODE_TOO_DEEP.with(Cell::get) {
            Err(too_deep())
        } else {
            Ok(())
        }
    }
}

impl Drop for DecodeScope {
    fn drop(&mut self) {
        let scopes = DECODE_SCOPES.with(Cell::get) - 1;
        DECODE_SCOPES.with(|cell| cell.set(scopes));
        if scopes == 0 {
            DECODE_TOO_DEEP.with(|flag| flag.set(false));
        }
    }
}

fn too_deep() -> Error {
    ArgumentError::raise(&format!(
        "value nested deeper than {MAX_DECODE_DEPTH} levels"
    ))
}

fn decode<'a>(term: Term<'a>) -> NifResult<Any> {
    match term.get_type() {
        TermType::Atom => {
            if let Ok(v) = term.decode::<bool>() {
                return Ok(Any::Bool(v));
            }

            let atom = term.decode::<types::atom::Atom>()?;
            if atom == types::atom::nil() {
                return Ok(Any::Null);
            }
            if atom == types::atom::undefined() {
                return Ok(Any::Undefined);
            }

            Err(rustler::Error::BadArg)
        }
        TermType::Integer => term.decode::<i64>().map(|v| Any::Number(Number::Int(v))),
        TermType::Float => term.decode::<f64>().map(|v| Any::Number(Number::Float(v))),
        TermType::Binary => {
            if let Ok(v) = term.decode::<&str>() {
                return Ok(Any::String(v.into()));
            }

            // Binaries that are not valid UTF-8 cannot be strings, so they are taken as a
            // Buffer, which reads back as `%Yex.Buffer{}`.
            term.decode::<Binary>()
                .map(|v| Any::Buffer(v.as_slice().into()))
        }
        TermType::List => {
            let _level = DepthGuard::enter()?;
            let iter = term.decode::<ListIterator<'a>>()?;
            let values = iter
                .map(decode)
                .collect::<Result<Vec<yrs::Any>, rustler::Error>>()?;
            // Not `Any::from`, which copies every element into a new vector first.
            Ok(Any::Array(values.into()))
        }
        TermType::Map => {
            if let Ok(buffer) = term.decode::<NifBuffer>() {
                return Ok(Any::Buffer(buffer.data.as_slice().into()));
            }

            let _level = DepthGuard::enter()?;
            let mut values = HashMap::with_capacity(term.map_size()?);
            for (k, v) in term.decode::<MapIterator<'a>>()? {
                values.insert(k.decode::<String>()?, decode(v)?);
            }
            // Not `Any::from`, which rehashes every entry into a new map first.
            Ok(Any::Map(Arc::new(values)))
        }
        _ => Err(rustler::Error::BadArg),
    }
}

pub type NifAny = NifWrap<Any>;

impl<'a> Decoder<'a> for NifAny {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        decode(term).map(|any| any.into())
    }
}

pub type NifAttr = NifWrap<HashMap<Arc<str>, Any>>;
impl<'a> Decoder<'a> for NifAttr {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        if let Ok(v) = term.decode::<MapIterator<'a>>() {
            let a = v
                .map(|(k, v)| Ok((k.decode::<&str>()?.into(), decode(v)?)))
                .collect::<Result<HashMap<Arc<str>, yrs::Any>, rustler::Error>>()?;
            return Ok(a.into());
        }
        Err(Error::BadArg)
    }
}

impl rustler::Encoder for NifAttr {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        encode_map(env, self.0.iter())
    }
}

#[rustler::nif]
fn normalize_number(any: NifAny) -> NifAny {
    // The data passes through Any, and gets converted.
    // For example, even numbers within the SAFE_INTEGER range are converted to float type.
    any
}
