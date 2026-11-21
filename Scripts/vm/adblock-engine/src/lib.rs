//! Brave's ad blocking engine (adblock-rust) for the helper's ad blocker: the calls of its Java
//! class io.github.inquiline.notifications.Engine. An engine is made once from the lists on for
//! an app and then asked from many connections at once.

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::{PermissionMask, Resource};
use adblock::Engine;
use jni::objects::{JBooleanArray, JClass, JObjectArray, JString};
use jni::sys::{jlong, jstring};
use jni::JNIEnv;
use std::collections::HashSet;

/// uBlock's own lists may use its scriptlets that need trust, as uBlock allows them alone.
const TRUSTED: PermissionMask = PermissionMask::from_bits(1);

fn text(env: &mut JNIEnv, value: &JString) -> String {
    if value.is_null() {
        return String::new();
    }
    env.get_string(value).map(|s| s.into()).unwrap_or_default()
}

fn out(env: &mut JNIEnv, value: Option<String>) -> jstring {
    match value {
        Some(v) => env.new_string(v).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
    }
}

fn engine<'a>(handle: jlong) -> &'a Engine {
    unsafe { &*(handle as *const Engine) }
}

/// `lists`: the lists' text; `trusted`: which are uBlock's own; `resources`: adblock-rust's
/// resource JSON (uBlock's scriptlets and stand-ins). Returns the engine, or 0.
#[no_mangle]
pub extern "system" fn Java_io_github_inquiline_notifications_Engine_create<'l>(
    mut env: JNIEnv<'l>,
    _: JClass<'l>,
    lists: JObjectArray<'l>,
    trusted: JBooleanArray<'l>,
    resources: JString<'l>,
) -> jlong {
    let count = env.get_array_length(&lists).unwrap_or(0) as usize;
    let mut flags = vec![0u8; count];
    if count > 0 {
        let _ = env.get_boolean_array_region(&trusted, 0, &mut flags);
    }
    let mut set = FilterSet::new(false);
    for (i, flag) in flags.iter().enumerate() {
        let Ok(item) = env.get_object_array_element(&lists, i as i32) else { continue };
        let list = text(&mut env, &JString::from(item));
        let opts = ParseOptions {
            permissions: if *flag != 0 { TRUSTED } else { PermissionMask::default() },
            ..ParseOptions::default()
        };
        set.add_filter_list(list, opts);
    }
    let mut engine = Engine::new_with_filter_set(set);
    let json = text(&mut env, &resources);
    if let Ok(list) = serde_json::from_str::<Vec<Resource>>(&json) {
        engine.use_resources(list);
    }
    Box::into_raw(Box::new(engine)) as jlong
}

#[no_mangle]
pub extern "system" fn Java_io_github_inquiline_notifications_Engine_free(_: JNIEnv, _: JClass, handle: jlong) {
    if handle != 0 {
        unsafe { drop(Box::from_raw(handle as *mut Engine)) };
    }
}

/// Null to let the request through; "" to block it; a data: address to answer it with.
#[no_mangle]
pub extern "system" fn Java_io_github_inquiline_notifications_Engine_check<'l>(
    mut env: JNIEnv<'l>,
    _: JClass<'l>,
    handle: jlong,
    url: JString<'l>,
    source: JString<'l>,
    kind: JString<'l>,
    method: JString<'l>,
) -> jstring {
    let (url, source, kind) = (text(&mut env, &url), text(&mut env, &source), text(&mut env, &kind));
    let method = text(&mut env, &method);
    let Ok(request) = Request::new(&url, if source.is_empty() { &url } else { &source }, &kind, &method) else {
        return std::ptr::null_mut();
    };
    let result = engine(handle).check_network_request(&request);
    let answer = if result.should_block() { Some(result.redirect.unwrap_or_default()) } else { None };
    out(&mut env, answer)
}

/// What a page needs to hide its ads, as JSON: the selectors to hide, the classes and ids
/// generic rules mustn't hide on it, the scriptlets to run first, and whether generic rules
/// apply at all.
#[no_mangle]
pub extern "system" fn Java_io_github_inquiline_notifications_Engine_cosmetic<'l>(
    mut env: JNIEnv<'l>,
    _: JClass<'l>,
    handle: jlong,
    url: JString<'l>,
) -> jstring {
    let url = text(&mut env, &url);
    let r = engine(handle).url_cosmetic_resources(&url);
    let json = serde_json::json!({
        "hide": r.hide_selectors.into_iter().collect::<Vec<_>>(),
        "exceptions": r.exceptions.into_iter().collect::<Vec<_>>(),
        "script": r.injected_script,
        "generichide": r.generichide,
    });
    out(&mut env, Some(json.to_string()))
}

/// The generic rules that hide something among these classes and ids (one per line), less
/// the page's exceptions, one per line: what uBlock and Brave ask as a page's elements appear.
#[no_mangle]
pub extern "system" fn Java_io_github_inquiline_notifications_Engine_hidden<'l>(
    mut env: JNIEnv<'l>,
    _: JClass<'l>,
    handle: jlong,
    classes: JString<'l>,
    ids: JString<'l>,
    exceptions: JString<'l>,
) -> jstring {
    let (classes, ids, exceptions) = (text(&mut env, &classes), text(&mut env, &ids), text(&mut env, &exceptions));
    let exceptions: HashSet<String> = exceptions.lines().filter(|s| !s.is_empty()).map(String::from).collect();
    let selectors = engine(handle).hidden_class_id_selectors(
        classes.lines().filter(|s| !s.is_empty()),
        ids.lines().filter(|s| !s.is_empty()),
        &exceptions,
    );
    out(&mut env, Some(selectors.join("\n")))
}
