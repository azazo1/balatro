//! WASM 只包装共用模型, 不包含另一套规则或历史实现.
use wasm_bindgen::prelude::*;
use lab::{error::Error,session::{Opening,Session}};

fn js_error(error: Error) -> JsValue {
    JsValue::from_str(&serde_json::json!({"status":error.status,"error":error.message}).to_string())
}

#[wasm_bindgen]
pub fn info() -> String { lab::view::info().to_string() }

#[wasm_bindgen]
pub struct Game { session: Session }

#[wasm_bindgen]
impl Game {
    #[wasm_bindgen(constructor)]
    pub fn new(opening_json: &str) -> Result<Game, JsValue> {
        console_error_panic_hook::set_once();
        let spec: Opening = serde_json::from_str(opening_json).map_err(|e|js_error(Error::bad(e.to_string())))?;
        // WASM 的随机种子由浏览器 crypto 生成, 不调用 std 的系统时钟.
        if spec.seed.is_empty() { return Err(js_error(Error::bad("浏览器须先生成种子"))); }
        Ok(Self { session:Session::new(spec).map_err(js_error)? })
    }

    pub fn observe(&self) -> String { lab::view::render(&self.session).to_string() }

    pub fn dispatch(&mut self, command_json: &str) -> Result<String,JsValue> {
        let command = serde_json::from_str(command_json).map_err(|e|js_error(Error::bad(e.to_string())))?;
        lab::command(&mut self.session,command).map_err(js_error)?;
        Ok(self.observe())
    }

    pub fn save(&self) -> Result<String,JsValue> { lab::format::export_text(&self.session).map_err(js_error) }

    pub fn actions(&self) -> Result<String,JsValue> { self.session.actions_jsonl().map_err(js_error) }

    pub fn restore(file_json: &str) -> Result<Game,JsValue> {
        console_error_panic_hook::set_once();
        let file = lab::format::decode(file_json).map_err(js_error)?;
        Ok(Self { session:lab::format::import(file).map_err(js_error)? })
    }
}
