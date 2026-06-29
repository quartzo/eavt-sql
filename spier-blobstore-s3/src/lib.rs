use std::collections::HashMap;
use std::io::Read;
use std::sync::Mutex;
use std::time::Duration;

use dynspire::*;

include!(concat!(env!("OUT_DIR"), "/blobstore_spier.rs"));

struct S3Inner {
    bucket: Option<rusty_s3::Bucket>,
    credentials: Option<rusty_s3::Credentials>,
    agent: Option<ureq::Agent>,
    prefix: String,
}

struct S3State {
    options: Mutex<HashMap<String, String>>,
    inner: Mutex<S3Inner>,
}

impl S3State {
    fn ensure_init(&self) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        if inner.bucket.is_some() {
            return Ok(());
        }
        let opts = self.options.lock().unwrap();
        let endpoint_str = opts.get("endpoint").ok_or("missing endpoint")?;
        let path_style_val = opts.get("path_style").map(|v| v == "true").unwrap_or(false);
        let bucket_name = opts.get("bucket_name").ok_or("missing bucket_name")?.to_string();
        let region = opts.get("region").ok_or("missing region")?.to_string();
        let access_key = opts.get("access_key").ok_or("missing access_key")?;
        let secret_key = opts.get("secret_key").ok_or("missing secret_key")?;
        let prefix = opts.get("prefix").cloned().unwrap_or_default();

        let endpoint = url::Url::parse(endpoint_str).map_err(|e| format!("invalid endpoint: {e}"))?;
        let url_style = if !path_style_val {
            rusty_s3::UrlStyle::Path
        } else {
            rusty_s3::UrlStyle::VirtualHost
        };
        let bucket = rusty_s3::Bucket::new(endpoint, url_style, bucket_name, region)
            .map_err(|e| format!("invalid bucket config: {e}"))?;
        let credentials = rusty_s3::Credentials::new(access_key, secret_key);
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(30))
            .build();

        inner.bucket = Some(bucket);
        inner.credentials = Some(credentials);
        inner.agent = Some(agent);
        inner.prefix = prefix;
        Ok(())
    }

    fn bucket(&self) -> Result<rusty_s3::Bucket, String> {
        self.ensure_init()?;
        self.inner.lock().unwrap().bucket.clone().ok_or("not initialized".into())
    }

    fn credentials(&self) -> Result<rusty_s3::Credentials, String> {
        self.ensure_init()?;
        self.inner.lock().unwrap().credentials.clone().ok_or("not initialized".into())
    }

    fn agent(&self) -> Result<ureq::Agent, String> {
        self.ensure_init()?;
        self.inner.lock().unwrap().agent.clone().ok_or("not initialized".into())
    }

    fn prefix(&self) -> Result<String, String> {
        self.ensure_init()?;
        Ok(self.inner.lock().unwrap().prefix.clone())
    }

    fn prefixed(&self, key: &str) -> Result<String, String> {
        let prefix = self.prefix()?;
        if prefix.is_empty() {
            Ok(key.to_string())
        } else {
            Ok(format!("{}/{}", prefix, key))
        }
    }

    fn blob_key(&self, id: &[u8; 16]) -> Result<String, String> {
        let hex = uuid_to_hex(id);
        self.prefixed(&format!("blobs/{}/{}/{}", &hex[0..2], &hex[2..4], hex))
    }

    fn root_key(&self, name: &str) -> Result<String, String> {
        self.prefixed(&format!("roots/{}", name))
    }

    fn s3_put(&self, key: &str, data: &[u8]) -> Result<(), String> {
        use rusty_s3::S3Action;
        let bucket = self.bucket()?;
        let credentials = self.credentials()?;
        let agent = self.agent()?;
        let action =
            rusty_s3::actions::PutObject::new(&bucket, Some(&credentials), key);
        let url = action.sign(Duration::from_secs(300));
        agent
            .put(url.as_str())
            .set("content-type", "application/octet-stream")
            .send_bytes(data)
            .map_err(|e| format!("s3 put: {e}"))?;
        Ok(())
    }

    fn s3_get(&self, key: &str) -> Result<Option<Vec<u8>>, String> {
        use rusty_s3::S3Action;
        let bucket = self.bucket()?;
        let credentials = self.credentials()?;
        let agent = self.agent()?;
        let action =
            rusty_s3::actions::GetObject::new(&bucket, Some(&credentials), key);
        let url = action.sign(Duration::from_secs(300));
        match agent.get(url.as_str()).call() {
            Ok(resp) => {
                let mut buf = Vec::new();
                resp.into_reader()
                    .read_to_end(&mut buf)
                    .map_err(|e| format!("s3 read body: {e}"))?;
                Ok(Some(buf))
            }
            Err(ureq::Error::Status(404, _)) => Ok(None),
            Err(e) => Err(format!("s3 get: {e}")),
        }
    }

    fn s3_delete(&self, key: &str) -> Result<(), String> {
        use rusty_s3::S3Action;
        let bucket = self.bucket()?;
        let credentials = self.credentials()?;
        let agent = self.agent()?;
        let action =
            rusty_s3::actions::DeleteObject::new(&bucket, Some(&credentials), key);
        let url = action.sign(Duration::from_secs(300));
        match agent.delete(url.as_str()).call() {
            Ok(_) => Ok(()),
            Err(ureq::Error::Status(404, _)) => Ok(()),
            Err(e) => Err(format!("s3 delete: {e}")),
        }
    }

    fn s3_list(
        &self,
        prefix: &str,
        token: Option<&str>,
    ) -> Result<rusty_s3::actions::ListObjectsV2Response, String> {
        use rusty_s3::S3Action;
        let bucket = self.bucket()?;
        let credentials = self.credentials()?;
        let agent = self.agent()?;
        let mut action =
            rusty_s3::actions::ListObjectsV2::new(&bucket, Some(&credentials));
        action.with_prefix(prefix);
        if let Some(t) = token {
            action.with_continuation_token(t);
        }
        let url = action.sign(Duration::from_secs(300));
        let resp = agent
            .get(url.as_str())
            .call()
            .map_err(|e| format!("s3 list: {e}"))?;
        let body = resp
            .into_string()
            .map_err(|e| format!("s3 list body: {e}"))?;
        rusty_s3::actions::ListObjectsV2::parse_response(&body)
            .map_err(|e| format!("s3 list parse: {e}"))
    }
}

fn s3_collect_list(state: &S3State, prefix: &str) -> Result<Vec<String>, String> {
    let mut items = Vec::new();
    let mut token = None;
    loop {
        let parsed = state.s3_list(prefix, token.as_deref())?;
        for obj in &parsed.contents {
            if let Some(rest) = obj.key.strip_prefix(prefix) {
                let name = rest.split('/').last().unwrap_or(rest);
                items.push(name.to_string());
            }
        }
        match parsed.next_continuation_token {
            Some(t) => token = Some(t),
            None => break,
        }
    }
    Ok(items)
}

fn init(config: &HashMap<String, String>) -> Result<S3State, String> {
    Ok(S3State {
        options: Mutex::new(config.clone()),
        inner: Mutex::new(S3Inner {
            bucket: None,
            credentials: None,
            agent: None,
            prefix: String::new(),
        }),
    })
}

impl BlobStoreEngine for S3State {
    fn put(&self, data: &[u8]) -> Result<[u8; 16], String> {
        let id = new_uuid();
        self.s3_put(&self.blob_key(&id)?, data)?;
        Ok(id)
    }

    fn put_at(&self, id: [u8; 16], data: &[u8]) -> Result<(), String> {
        self.s3_put(&self.blob_key(&id)?, data)
    }

    fn delete(&self, id: [u8; 16]) -> Result<(), String> {
        self.s3_delete(&self.blob_key(&id)?)
    }

    fn get(&self, id: [u8; 16]) -> Result<Option<Vec<u8>>, String> {
        let key = self.blob_key(&id)?;
        self.s3_get(&key)
    }

    fn list(&self) -> Result<Vec<[u8; 16]>, String> {
        let prefix = self.prefixed("blobs/")?;
        let names = s3_collect_list(self, &prefix)?;
        Ok(names.iter().filter_map(|n| uuid_from_hex(n)).collect())
    }

    fn put_root(&self, name: &str, data: &[u8]) -> Result<(), String> {
        self.s3_put(&self.root_key(name)?, data)
    }

    fn get_root(&self, name: &str) -> Result<Option<Vec<u8>>, String> {
        let key = self.root_key(name)?;
        self.s3_get(&key)
    }

    fn list_roots(&self) -> Result<Vec<String>, String> {
        let prefix = self.prefixed("roots/")?;
        let names = s3_collect_list(self, &prefix)?;
        let mut roots: Vec<String> = names.into_iter().filter(|n| n.starts_with("root_")).collect();
        roots.sort();
        Ok(roots)
    }

    fn delete_root(&self, name: &str) -> Result<(), String> {
        self.s3_delete(&self.root_key(name)?)
    }
}

impl_blobstore_spier!(S3State, init, "spier_blobstore_s3");
