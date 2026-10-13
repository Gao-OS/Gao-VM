use serde_json::{Value, json};

fn schemas() -> [Value; 2] {
    [
        serde_json::from_str(include_str!("../../../schemas/guest-bridge/v1.schema.json")).unwrap(),
        serde_json::from_str(include_str!("../../../schemas/guest-binary/v1.schema.json")).unwrap(),
    ]
}

#[test]
fn independent_opening_examples_match_the_accepted_contracts() {
    for schema in schemas() {
        let validator = jsonschema::validator_for(&schema).unwrap();
        for example in schema["examples"].as_array().unwrap() {
            assert!(validator.is_valid(example), "{example}");
        }
    }
}

#[test]
fn all_headers_require_exact_correlation_and_disallow_unknown_fields() {
    for schema in schemas() {
        let validator = jsonschema::validator_for(&schema).unwrap();
        for example in schema["examples"].as_array().unwrap() {
            for field in example.as_object().unwrap().keys() {
                let mut bad = example.clone();
                bad.as_object_mut().unwrap().remove(field);
                assert!(!validator.is_valid(&bad), "missing {field}: {bad}");
            }
            for (field, value) in [
                ("protocol_version", json!("gaovm.unknown.v1")),
                ("vm_id", json!("vm_81J00000000000000000000000")),
                ("driver_generation", json!(0)),
                ("operation_id", json!("op_bad")),
                ("path", json!("/must-not-be-accepted")),
                ("port", json!(10777)),
            ] {
                let mut bad = example.clone();
                bad[field] = value;
                assert!(!validator.is_valid(&bad), "{field}: {bad}");
            }
        }
        for bad in [json!([]), json!(null), json!("text"), json!(true)] {
            assert!(!validator.is_valid(&bad));
        }
    }
}

#[test]
fn bridge_binary_operations_are_required_and_responses_never_echo_tokens() {
    let schema = &schemas()[0];
    let validator = jsonschema::validator_for(schema).unwrap();
    let examples = schema["examples"].as_array().unwrap();
    let mut binary = examples[2].clone();
    binary["operation_id"] = Value::Null;
    assert!(!validator.is_valid(&binary));
    for response in [&examples[1], &examples[3], &examples[4]] {
        let mut bad = response.clone();
        bad["auth_token"] = json!("must-not-be-echoed");
        assert!(!validator.is_valid(&bad));
        bad.as_object_mut().unwrap().remove("auth_token");
        bad["message"] = json!("must-not-be-echoed");
        assert!(!validator.is_valid(&bad));
    }
}

#[test]
fn binary_selectors_descriptors_and_acknowledgements_are_not_extensible() {
    let schema = &schemas()[1];
    let validator = jsonschema::validator_for(schema).unwrap();
    let examples = schema["examples"].as_array().unwrap();
    for (index, field) in [(0, "source"), (1, "source"), (2, "artifact"), (4, "error")] {
        let mut bad = examples[index].clone();
        bad[field]["path"] = json!("/untrusted");
        assert!(!validator.is_valid(&bad));
    }
    for (index, field, value) in [
        (0, "stream_id", json!("not-a-csprng-handle")),
        (1, "output", json!("combined")),
        (2, "size_bytes", json!(268435457)),
        (2, "digest", json!("sha256:bad")),
        (2, "stream_id", json!("A".repeat(64))),
    ] {
        let mut bad = examples[index].clone();
        let nested = if index == 2 { "artifact" } else { "source" };
        bad[nested][field] = value;
        assert!(!validator.is_valid(&bad));
    }
    for example in examples {
        let mut bad = example.clone();
        bad["operation_id"] = Value::Null;
        assert!(!validator.is_valid(&bad));
    }
}
