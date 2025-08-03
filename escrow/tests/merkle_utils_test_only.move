#[test_only]
module escrow::merkle_utils_testonly {
    use sui::hash;

    /// -------- byte helpers --------

    /// a < b (lexicographic)
    public fun bytes_lt(a: &vector<u8>, b: &vector<u8>) : bool {
        let la = vector::length(a);
        let lb = vector::length(b);
        let n = if (la < lb) { la } else { lb };
        let mut i = 0;
        while (i < n) {
            let ba = *vector::borrow(a, i);
            let bb = *vector::borrow(b, i);
            if (ba < bb) return true;
            if (ba > bb) return false;
            i = i + 1;
        };
        la < lb
    }

    /// a == b
    public fun bytes_eq(a: &vector<u8>, b: &vector<u8>) : bool {
        let la = vector::length(a);
        let lb = vector::length(b);
        if (la != lb) return false;
        let mut same = true;
        let mut i = 0;
        while (i < la) {
            if (*vector::borrow(a, i) != *vector::borrow(b, i)) { same = false };
            i = i + 1;
        };
        same
    }

    /// a || b
    fun cat(a: &vector<u8>, b: &vector<u8>) : vector<u8> {
        let mut out = *a;
        vector::append(&mut out, *b);
        out
    }

    /// -------- hashing rules (match your verifier) --------

    /// Leaf hash
    public fun leaf(secret: &vector<u8>) : vector<u8> {
        hash::keccak256(secret)
    }

    /// Parent hash: keccak(min(a,b)||max(a,b))
    public fun parent(a: &vector<u8>, b: &vector<u8>) : vector<u8> {
        if (bytes_lt(a, b)) {
            hash::keccak256(&cat(a, b))
        } else {
            hash::keccak256(&cat(b, a))
        }
    }

    /// Build leaf hashes from raw secrets
    public fun leaves_from_secrets(secrets: &vector<vector<u8>>) : vector<vector<u8>> {
        let mut leaves = vector::empty<vector<u8>>();
        let mut i = 0;
        let n = vector::length(secrets);
        while (i < n) {
            let s = vector::borrow(secrets, i);
            vector::push_back(&mut leaves, leaf(s));
            i = i + 1;
        };
        leaves
    }

    /// Root from **leaf hashes**. Rule: duplicate last if odd.
    public fun root_from_leaves(mut level: vector<vector<u8>>) : vector<u8> {
        if (vector::length(&level) == 0) {
            // define policy; here: keccak256([])
            return hash::keccak256(&vector::empty<u8>())
        };
        while (vector::length(&level) > 1) {
            let mut next = vector::empty<vector<u8>>();
            let mut i = 0;
            let m = vector::length(&level);
            while (i < m) {
                let l = vector::borrow(&level, i);
                let r = if (i + 1 < m) { vector::borrow(&level, i + 1) } else { vector::borrow(&level, i) };
                vector::push_back(&mut next, parent(l, r));
                i = i + 2;
            };
            level = next;
        };
        *vector::borrow(&level, 0)
    }

    /// Root from **raw secrets**
    public fun root_from_secrets(secrets: &vector<vector<u8>>) : vector<u8> {
        root_from_leaves(leaves_from_secrets(secrets))
    }

    /// Proof for a leaf index from **leaf hashes** (duplicate last if odd)
    public fun proof_for_index_from_leaves(mut level: vector<vector<u8>>, mut idx: u64)
        : vector<vector<u8>>
    {
        let mut proof = vector::empty<vector<u8>>();
        if (vector::length(&level) == 0) return proof;

        while (vector::length(&level) > 1) {
            let m = vector::length(&level);
            let is_right = (idx % 2 == 1);
            let sib_idx = if (is_right) { idx - 1 }
                          else if (idx + 1 < (m as u64)) { idx + 1 }
                          else { idx }; // duplicate last
            let sib = *vector::borrow(&level, (sib_idx as u64));
            vector::push_back(&mut proof, sib);

            // next level
            let mut next = vector::empty<vector<u8>>();
            let mut i = 0;
            while (i < m) {
                let l = vector::borrow(&level, i);
                let r = if (i + 1 < m) { vector::borrow(&level, i + 1) } else { vector::borrow(&level, i) };
                vector::push_back(&mut next, parent(l, r));
                i = i + 2;
            };
            level = next;
            idx = idx / 2;
        };
        proof
    }

    /// Proof for a leaf index from **raw secrets**
    public fun proof_for_index_from_secrets(secrets: &vector<vector<u8>>, index: u64)
        : vector<vector<u8>>
    {
        proof_for_index_from_leaves(leaves_from_secrets(secrets), index)
    }

    /// Verifier compatible with your production `verify_merkle_proof`
    public fun verify(leaf_hash: &vector<u8>, proof: &vector<vector<u8>>, root: &vector<u8>) : bool {
        let mut acc = *leaf_hash;
        let mut i = 0;
        let n = vector::length(proof);
        while (i < n) {
            let sib = vector::borrow(proof, i);
            acc = if (bytes_lt(&acc, sib)) { hash::keccak256(&cat(&acc, sib)) }
                  else { hash::keccak256(&cat(sib, &acc)) };
            i = i + 1;
        };
        bytes_eq(&acc, root)
    }
}
