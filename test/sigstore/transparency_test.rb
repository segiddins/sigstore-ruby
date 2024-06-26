# frozen_string_literal: true

require "test_helper"
require "sigstore/transparency"

class Sigstore::Transparency::LogEntryTest < Test::Unit::TestCase
  def test_consistency
    e = assert_raise(ArgumentError) do
      Sigstore::Transparency::LogEntry.new(
        uuid: "fake",
        body: ["fake"].pack("m0"),
        integrated_time: 0,
        log_id: "1234",
        log_index: 1,
        inclusion_proof: nil,
        inclusion_promise: nil
      )
    end

    assert_equal("LogEntry must have either inclusion_proof or inclusion_promise", e.message)
  end

  def test_from_response
    body = {
      "kind" => "hashedrekord",
      "apiVersion" => "0.0.1"
    }
    entry = Sigstore::Transparency::LogEntry.from_response(
      "fake" => {
        "body" => [JSON.dump(body)].pack("m0"),
        "integratedTime" => 0,
        "logID" => "1234",
        "logIndex" => 1,
        "verification" => {
          "inclusionProof" => {
            "checkpoint" => "fake",
            "hashes" => ["fake"],
            "logIndex" => 1,
            "rootHash" => "fake",
            "treeSize" => 1
          }
        }
      }
    )

    assert_equal Sigstore::Transparency::LogEntry.new(
      uuid: "fake",
      body: [JSON.dump(body)].pack("m0"),
      integrated_time: 0,
      log_id: "1234",
      log_index: 1,
      inclusion_proof: Sigstore::Transparency::InclusionProof.new(
        checkpoint: "fake",
        hashes: ["fake"],
        log_index: 1,
        root_hash: "fake",
        tree_size: 1
      ),
      inclusion_promise: nil
    ), entry

    e = assert_raise(ArgumentError) do
      Sigstore::Transparency::LogEntry.from_response([])
    end
    assert_equal("response must be a Hash", e.message)

    e = assert_raise(ArgumentError) do
      Sigstore::Transparency::LogEntry.from_response("fake" => {}, "fake2" => {})
    end
    assert_equal("Received multiple entries in response", e.message)

    e = assert_raise(RuntimeError) do
      Sigstore::Transparency::LogEntry.from_response(
        "fake" => {
          "body" => [JSON.dump({})].pack("m0"),
          "integratedTime" => 0,
          "logID" => "1234",
          "logIndex" => 1,
          "verification" => {
            "inclusionProof" => {
              "checkpoint" => "fake",
              "hashes" => ["fake"],
              "logIndex" => 1,
              "rootHash" => "fake",
              "treeSize" => 1
            }
          }
        }
      )
    end
    assert_equal("Invalid entry body: {}. Expected kind: hashedrekord, apiVersion: 0.0.1", e.message)
  end

  def test_encode_canonical
    body = {
      "kind" => "hashedrekord",
      "apiVersion" => "0.0.1"
    }
    entry = Sigstore::Transparency::LogEntry.from_response(
      "fake" => {
        "body" => [JSON.dump(body)].pack("m0"),
        "integratedTime" => 0,
        "logID" => "1234",
        "logIndex" => 1,
        "verification" => {
          "inclusionProof" => {
            "checkpoint" => "fake",
            "hashes" => ["fake"],
            "logIndex" => 1,
            "rootHash" => "fake",
            "treeSize" => 1
          }
        }
      }
    )

    assert_equal <<~CANONICAL.chomp, entry.encode_canonical
      {"body":"eyJraW5kIjoiaGFzaGVkcmVrb3JkIiwiYXBpVmVyc2lvbiI6IjAuMC4xIn0=","integratedTime":0,"logID":"1234","logIndex":1}
    CANONICAL
  end
end

# TODO: https://github.com/transparency-dev/merkle/blob/main/proof/verify_test.go
class Sigstore::Transparency::InclusionProofTest < Test::Unit::TestCase
  def test_hasher
    [
      # ["RFC6962 Empty", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", ],
      ["RFC6962 Empty Leaf", "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
       Sigstore::Internal::Merkle.hash_leaf("")],
      ["RFC6962 Single Leaf", "395aa064aa4c29f7010acfe3f25db9485bbd4b91897b6ad7ad547639252b4d56",
       Sigstore::Internal::Merkle.hash_leaf("L123456")],
      ["RFC6962 Node", "aa217fe888e47007fa15edab33c2b492a722cb106c64667fc2b044444de66bbb",
       Sigstore::Internal::Merkle.hash_children("N123", "N456")]
    ].each do |desc, got, want|
      got_hex = [got].pack("H*")
      assert_equal got_hex, want, desc
    end
  end

  def test_hasher_collisions
    leaf1 = "Hello"
    leaf2 = "World"

    hash1 = Sigstore::Internal::Merkle.hash_leaf(leaf1)
    hash2 = Sigstore::Internal::Merkle.hash_leaf(leaf2)

    refute_equal hash1, hash2, "Leaf hashes should differ"

    sub_hash1 = Sigstore::Internal::Merkle.hash_children(hash1, hash2)
    preimage = "#{hash1}#{hash2}"
    forged_hash = Sigstore::Internal::Merkle.hash_leaf(preimage)

    refute_equal sub_hash1, forged_hash, "Hasher is not second-preimage resistant"

    sub_hash2 = Sigstore::Internal::Merkle.hash_children(hash2, hash1)

    refute_equal sub_hash1, sub_hash2, "Hasher is not order-sensitive"
  end

  def test_verify_inclusion_single_entry
    data = "data"
    # Root and leaf hash for 1-entry tree are the same.
    hash = Sigstore::Internal::Merkle.hash_leaf(data)
    # The corresponding inclusion proof is empty.
    proof = []
    empty_hash = ""

    [
      [hash, hash, false],
      [hash, empty_hash, true],
      [empty_hash, hash, true],
      [empty_hash, empty_hash, true] # wrong hash size
    ].each do |root, leaf, want_err|
      blk = proc do
        Sigstore::Internal::Merkle.verify_inclusion(
          0, 1, proof, root, leaf
        )
      end
      if want_err
        assert_raise(Sigstore::Internal::Merkle::InvalidInclusionProofError, &blk)
      else
        blk.call
      end
    end
  end

  def verifier_check(leaf_index, tree_size, proof, root, leaf_hash)
    got = Sigstore::Internal::Merkle.root_from_inclusion_proof(
      Sigstore::Transparency::InclusionProof.new(
        hashes: proof,
        log_index: leaf_index,
        tree_size: tree_size
      ),
      leaf_hash
    )

    assert_equal root, [got].pack("H*"), "got root #{got}, want #{root}"
  end
end
