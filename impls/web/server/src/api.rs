use std::{collections::HashMap,path::PathBuf,sync::{Arc,Mutex}};
use axum::{extract::{DefaultBodyLimit,Path,State},http::{StatusCode,header},middleware::{self,Next},response::{IntoResponse,Response},routing::{get,post},Json,Router};
use lab::{error::{Error,Result},format,session::{Opening,Session},Command};
use serde_json::{Value,json};
use tower_http::{services::ServeDir,trace::TraceLayer};

pub struct ApiError(pub Error);
impl From<Error> for ApiError { fn from(e:Error)->Self { Self(e) } }
impl IntoResponse for ApiError {
    fn into_response(self)->Response {
        (StatusCode::from_u16(self.0.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),Json(json!({"error":self.0.message}))).into_response()
    }
}
type ApiResult<T> = std::result::Result<T,ApiError>;

#[derive(Clone)]
pub struct AppState {
    sessions: Arc<Mutex<HashMap<String,Arc<Mutex<Session>>>>>,
    pub port: u16,
    pub dev_origin: Option<String>,
}

impl AppState {
    pub fn new(port:u16,dev_origin:Option<String>)->Self { Self { sessions:Arc::default(),port,dev_origin } }
    fn get(&self,id:&str)->Result<Arc<Mutex<Session>>> {
        self.sessions.lock().map_err(|_|Error::internal())?.get(id).cloned().ok_or_else(Error::missing)
    }
    fn insert(&self,session:Session)->Result<String> {
        let mut sessions = self.sessions.lock().map_err(|_|Error::internal())?;
        if sessions.len()>=8 { return Err(Error::refused("最多同时保留 8 个会话, 请先关闭不需要的会话")); }
        let mut id = engine::opening::generate_seed();
        while sessions.contains_key(&id) { id = engine::opening::generate_seed(); }
        sessions.insert(id.clone(),Arc::new(Mutex::new(session)));
        Ok(id)
    }
}

pub fn router(state:AppState,static_dir:PathBuf)->Router {
    Router::new()
        .route("/api/v1/info",get(||async { Json(lab::view::info()) }))
        .route("/api/v1/sessions",post(create))
        .route("/api/v1/import",post(import))
        .route("/api/v1/sessions/{id}",get(observe).delete(remove))
        .route("/api/v1/sessions/{id}/commands",post(dispatch))
        .route("/api/v1/sessions/{id}/preview",post(preview))
        .route("/api/v1/sessions/{id}/save",get(save))
        .route("/api/v1/sessions/{id}/actions",get(actions))
        .route("/api/{*path}",get(||async { ApiError(Error::missing()).into_response() }))
        .fallback_service(ServeDir::new(static_dir))
        .layer(DefaultBodyLimit::max(format::MAX_FILE_BYTES))
        .layer(middleware::from_fn_with_state(state.clone(),guard))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn guard(State(state):State<AppState>,request:axum::extract::Request,next:Next)->Response {
    let headers = request.headers();
    let hosts = [format!("127.0.0.1:{}",state.port),format!("localhost:{}",state.port)];
    let host_ok = headers.get(header::HOST).and_then(|h|h.to_str().ok()).is_some_and(|h|hosts.iter().any(|v|v==h));
    let origin_ok = headers.get(header::ORIGIN).is_none_or(|h|h.to_str().ok().is_some_and(|origin|
        hosts.iter().any(|h|format!("http://{h}")==origin) || state.dev_origin.as_deref()==Some(origin)));
    if !host_ok || !origin_ok { return (StatusCode::FORBIDDEN,Json(json!({"error":"拒绝非本地来源请求"}))).into_response(); }
    let mut response = next.run(request).await;
    response.headers_mut().insert(header::CACHE_CONTROL,"no-store".parse().expect("合法 header"));
    response.headers_mut().insert(header::X_CONTENT_TYPE_OPTIONS,"nosniff".parse().expect("合法 header"));
    response
}

fn view(id:&str,session:&Session)->Value {
    let mut value = lab::view::render(session);
    value["session_id"] = json!(id);
    value
}

/// 引擎执行在 blocking pool 中运行, 不阻塞 HTTP runtime.
async fn with_session<T:Send+'static>(state:AppState,id:String,f:impl FnOnce(&mut Session)->Result<T>+Send+'static)->ApiResult<T> {
    let session = state.get(&id)?;
    tokio::task::spawn_blocking(move|| {
        let mut session = session.lock().map_err(|_|Error::internal())?;
        f(&mut session)
    }).await.map_err(|e| { tracing::error!(error=%e,"会话任务失败");ApiError(Error::internal()) })?.map_err(ApiError)
}

async fn create(State(state):State<AppState>,Json(opening):Json<Opening>)->ApiResult<Json<Value>> {
    let session = tokio::task::spawn_blocking(move||Session::new(opening)).await.map_err(|_|ApiError(Error::internal()))??;
    tracing::info!(seed=%session.opening.seed,deck=%session.opening.deck,stake=session.opening.stake,"新建对局");
    let id = state.insert(session)?;
    let value = with_session(state,id.clone(),move|s|Ok(view(&id,s))).await?;
    Ok(Json(value))
}

async fn observe(State(state):State<AppState>,Path(id):Path<String>)->ApiResult<Json<Value>> {
    Ok(Json(with_session(state,id.clone(),move|s|Ok(view(&id,s))).await?))
}

async fn dispatch(State(state):State<AppState>,Path(id):Path<String>,Json(command):Json<Command>)->ApiResult<Json<Value>> {
    Ok(Json(with_session(state,id.clone(),move|s| {
        lab::command(s,command).inspect_err(|e|tracing::warn!(status=e.status,error=%e.message,"拒绝对局操作"))?;
        Ok(view(&id,s))
    }).await?))
}

async fn preview(State(state):State<AppState>,Path(id):Path<String>,Json(request):Json<lab::PreviewRequest>)->ApiResult<Json<Value>> {
    Ok(Json(with_session(state,id,move|s|lab::preview(s,&request)).await?))
}

async fn save(State(state):State<AppState>,Path(id):Path<String>)->ApiResult<Response> {
    let text = with_session(state,id,|s|format::export_text(s)).await?;
    Ok(([(header::CONTENT_TYPE,"application/json")],text).into_response())
}

async fn actions(State(state):State<AppState>,Path(id):Path<String>)->ApiResult<String> {
    with_session(state,id,|s|s.actions_jsonl()).await
}

async fn import(State(state):State<AppState>,Json(file):Json<format::File>)->ApiResult<Json<Value>> {
    let candidate = tokio::task::spawn_blocking(move||format::import(file)).await.map_err(|e| {
        tracing::error!(error=%e,"导入任务失败");ApiError(Error::internal())
    })??;
    let id = state.insert(candidate)?;
    Ok(Json(with_session(state,id.clone(),move|s|Ok(view(&id,s))).await?))
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Revision { revision:u64 }
async fn remove(State(state):State<AppState>,Path(id):Path<String>,Json(revision):Json<Revision>)->ApiResult<Json<Value>> {
    let mut sessions = state.sessions.lock().map_err(|_|ApiError(Error::internal()))?;
    let session = sessions.get(&id).ok_or_else(Error::missing)?;
    session.lock().map_err(|_|Error::internal())?.check_revision(revision.revision)?;
    sessions.remove(&id);
    tracing::info!(id,"关闭会话");
    Ok(Json(json!({"ok":true})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body,http::Request};
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    async fn call(router:&Router,path:&str,body:Value,origin:&str)->(StatusCode,Value) {
        let response = router.clone().oneshot(Request::builder().method("POST").uri(path)
            .header("host","127.0.0.1:12347").header("origin",origin).header("content-type","application/json")
            .body(Body::from(body.to_string())).unwrap()).await.unwrap();
        let status = response.status();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        (status,serde_json::from_slice(&bytes).unwrap())
    }

    #[tokio::test]
    async fn rejects_foreign_origin_and_stale_revision() {
        let app = router(AppState::new(12347,None),PathBuf::from("missing-static"));
        let opening = json!({"seed":"ALEEB","deck":"RED","stake":1,"profile":"all"});
        assert_eq!(call(&app,"/api/v1/sessions",opening.clone(),"https://evil.example").await.0,StatusCode::FORBIDDEN);
        let (status,created) = call(&app,"/api/v1/sessions",opening,"http://127.0.0.1:12347").await;
        assert_eq!(status,StatusCode::OK);
        let path = format!("/api/v1/sessions/{}/commands",created["session_id"].as_str().unwrap());
        let command = json!({"kind":"action","revision":0,"action":{"method":"select","params":{}}});
        assert_eq!(call(&app,&path,command.clone(),"http://127.0.0.1:12347").await.0,StatusCode::OK);
        assert_eq!(call(&app,&path,command,"http://127.0.0.1:12347").await.0,StatusCode::CONFLICT);
        assert_eq!(call(&app,&path,json!({"kind":"edit","revision":1,"changes":{"dollars":100}}),"http://127.0.0.1:12347").await.0,StatusCode::UNPROCESSABLE_ENTITY);
    }
}
