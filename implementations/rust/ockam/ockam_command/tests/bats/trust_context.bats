#!/bin/bash

# ===== SETUP

setup() {
    load load/base.bash
    load load/orchestrator.bash
    load_bats_ext
    setup_home_dir
}

teardown() {
    teardown_home_dir
}

# ===== TESTS

@test "trust context - no trust context; everything is accepted" {
    run "$OCKAM" identity create m1
    run "$OCKAM" node create n1 --identity m1

    run "$OCKAM" identity create m2
    run "$OCKAM" node create n2 --identity m2

    run bash -c "$OCKAM secure-channel create --from /node/n1 --to /node/n2/service/api \
        | $OCKAM message send hello --from /node/n1 --to -/service/echo"
    assert_success
}

@test "trust context - trust context with an id only; ABAC rules are applied" {
    echo "{
        \"id\": \"1\"
    }" > ./trust_context.json

    run "$OCKAM" identity create m1

    m1_identifier=$(run "$OCKAM"  identity show m1)
    trusted="{\"$m1_identifier\": {\"sample_attr\": \"sample_val\", \"project_id\" : \"1\", \"trust_context_id\" : \"1\"}}"

    run "$OCKAM" node create n1 --identity m1

    run "$OCKAM" node create n2  --trust-context ./trust_context.json --trusted-identities "$trusted"

    run bash -c "$OCKAM secure-channel create --from /node/n1 --to /node/n2/service/api \
        | $OCKAM message send hello --from /node/n1 --to -/service/echo"
    assert_success

    run "$OCKAM" message send hello --timeout 2 --from /node/n1 --to /node/n2/service/echo
    assert_failure
}

@test "trust context - trust context with an offline authority; Credential Exchange is performed" {
    port=8005
    # Create two identities
    run "$OCKAM" identity create alice
    alice_identity=$($OCKAM identity show alice --full --encoding hex)

    run "$OCKAM" identity create bob
    bob_identity=$($OCKAM identity show bob --full --encoding hex)

    $OCKAM identity create attacker

    # Create an identity that both alice and bob will trust
    run "$OCKAM" identity create authority
    authority_identity=$($OCKAM identity show authority --full --encoding hex)

    # issue and store credentials for alice
    $OCKAM credential issue --as authority --for $alice_identity --attribute city="New York" --encoding hex > alice.cred
    run "$OCKAM" credential store alice-cred --issuer $authority_identity --credential-path alice.cred
    $OCKAM credential show alice-cred --as-trust-context > ./alice-trust-context.json

    # issue and store credential for bob
    $OCKAM credential issue --as authority --for $bob_identity --attribute city="New York" --encoding hex > bob.cred
    run "$OCKAM" credential store bob-cred --issuer $authority_identity --credential-path bob.cred
    $OCKAM credential show bob-cred --as-trust-context > ./bob-trust-context.json

    # Create a node for alice that trust authority as a credential authority
    run "$OCKAM" node create alice --tcp-listener-address 127.0.0.1:$port  --identity alice --trust-context alice-trust-context.json

    msg=$(random_str)

    # Fail, attacker won't present any credential
    run $OCKAM message send --timeout 2 --identity attacker --to /dnsaddr/127.0.0.1/tcp/$port/secure/api/service/echo  $msg
    assert_failure

    # Fail, attacker will present an invalid credential (self signed rather than signed by authority)
    $OCKAM credential issue --as attacker --for $($OCKAM identity show attacker --full --encoding hex) --encoding hex > "$OCKAM_HOME/attacker.cred"
    $OCKAM credential store att-cred --issuer $authority_identity --credential-path $OCKAM_HOME/attacker.cred
    $OCKAM credential show att-cred --as-trust-context > ./att-trust-context.json
    run $OCKAM message send --timeout 2 --identity attacker --to /dnsaddr/127.0.0.1/tcp/$port/secure/api/service/echo  --trust-context ./att-trust-context.json  $msg
    assert_failure

    # Fail, attacker will present an invalid credential (bob' credential, not own)
    run "$OCKAM" message send --timeout 2 --identity attacker --to /dnsaddr/127.0.0.1/tcp/$port/secure/api/service/echo  --trust-context ./bob-trust-context.json $msg
    assert_failure

    run "$OCKAM" message send --timeout 2 --identity bob --to /dnsaddr/127.0.0.1/tcp/$port/secure/api/service/echo  --trust-context ./bob-trust-context.json $msg
    assert_success
    assert_output $msg

    $OCKAM node delete alice
    echo "{\"id\": \"$authority_id\"}" > alice-trust-context.json
    $OCKAM node create alice --tcp-listener-address 127.0.0.1:$port  --identity alice --trust-context ./alice-trust-context.json

    run "$OCKAM" message send --timeout 2 --identity bob --to /dnsaddr/127.0.0.1/tcp/$port/secure/api/service/echo  --trust-context ./bob-trust-context.json $msg
    assert_failure
}

@test "trust context - trust context with an online authority; Credential Exchange is performed" {
  port=8007
  $OCKAM identity create alice
  $OCKAM identity create bob
  $OCKAM identity create attacker
  $OCKAM identity create authority
  bob_id=$($OCKAM identity show bob)
  alice_id=$($OCKAM identity show alice)
  authority_identity=$($OCKAM identity show --full --encoding hex  authority)

  trusted="{\"$bob_id\": {}, \"$alice_id\": {}}"
  $OCKAM authority create --identity authority --tcp-listener-address=127.0.0.1:4200 --project-identifier "test-context" --trusted-identities "$trusted"

  echo "{\"id\": \"test-context\",
        \"authority\" : {
            \"identity\" : \"$authority_identity\",
            \"own_credential\" :{
                \"FromCredentialIssuer\" : {
                    \"identity\": \"$authority_identity\",
                    \"maddr\" : \"/dnsaddr/127.0.0.1/tcp/4200/service/api\" }}}}" > ./trust_context.json

  $OCKAM node create --identity alice --tcp-listener-address 127.0.0.1:$port --trust-context ./trust_context.json

  msg=$(random_str)
  run "$OCKAM" message send --identity bob --to /dnsaddr/127.0.0.1/tcp/$port/secure/api/service/echo  --trust-context ./trust_context.json $msg
  assert_success
  assert_output "$msg"

  run "$OCKAM" message send --timeout 2 --identity attacker --to /dnsaddr/127.0.0.1/tcp/$port/secure/api/service/echo  --trust-context ./trust_context.json $msg
  assert_failure
  run "$OCKAM" message send --timeout 2 --identity attacker --to /dnsaddr/127.0.0.1/tcp/$port/secure/api/service/echo  --trust-context $msg
  assert_failure
}

@test "trust context - trust context with an id and authority using orchestrator; orchestrator enrollment and connection is performed, orchestrator" {
    skip_if_orchestrator_tests_not_enabled
    load_orchestrator_data

    $OCKAM project information --as-trust-context > ./project_trust_context.json

    run "$OCKAM" identity create m1
    $OCKAM project enroll > m1.token
    run "$OCKAM" project authenticate --identity m1 --trust-context ./project_trust_context.json --token $(cat m1.token)

    run "$OCKAM" identity create m2
    $OCKAM project enroll > m2.token
    run "$OCKAM" project authenticate --identity m2 --trust-context ./project_trust_context.json --token $(cat m2.token)

    run "$OCKAM" node create n1 --identity m1 --trust-context ./project_trust_context.json
    assert_success

    run "$OCKAM" node create n2 --identity m2 --trust-context ./project_trust_context.json
    assert_success

    run bash -c "$OCKAM secure-channel create --from /node/n1 --to /node/n2/service/api \
        | $OCKAM message send hello --from /node/n1 --to -/service/echo"
    assert_success
}
