# Workspace Notebooks R & ADBC Setup – Conversation

Below is a transcript-style capture of the conversation between **Simon** (user) and the assistant about Snowflake Workspace Notebooks, R, rpy2, ADBC, SPCS tokens, and PAT authentication.

---

**User:** I have created a Snowflake Model Service.   But service status is suspended.  If I then do model\_version.run() will it resume the service?

**Assistant:** **Short answer:**

- `model_version.run(...)` **without** a `service_name` does **not** touch the service; it runs in a warehouse.  
- `model_version.run(..., service_name="your_service")` **does** send traffic to the model service and will **auto‑resume** it if it was auto‑suspended (scale‑to‑zero), assuming `auto_resume` is enabled (the default for model services).

Then explains:

- The two modes of `ModelVersion.run` (warehouse vs service).  
- SPCS auto-suspend and auto-resume behavior and that incoming requests will trigger a resume when `min_instances=0` scale-to-zero is in play.

Practical guidance:

```py
service_prediction = model_version.run(
    test_df,
    function_name="predict",
    service_name="my_service",
)
```

If you created a standard model service with default settings (auto\_resume true, min\_instances possibly 0), then `model_version.run(..., service_name=...)` will wake it up.


(End of transcript.)  
