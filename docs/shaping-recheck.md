Queued approvals retain their recorded assumptions in the immutable Intent. Optional
frontmatter `assumptions` and `shared_contracts` each accept a list of `name`, `path`,
and `contains` maps. `contains` is the smallest stable observable contract text,
not a hash of an entire source file. For example:

```yaml
assumptions:
  - name: guests can browse
    path: docs/access.md
    contains: Guests may browse public projects.
shared_contracts:
  - name: creation response
    path: docs/api.md
    contains: POST /projects returns 201.
blocks_on: [public-projects]
```

Approval verifies the file predicates against the target base. Dependencies may
still be queued at approval; before Build, every `blocks_on` Intent must have a
landed outcome on that branch. The pre-start recheck records matched predicates,
current base and dependency landing commits in `shaping_rechecked`. Missing or
changed predicates record `shaping_stale`, identify the assumption and require
reshaping or renewed approval with updated assumptions. Status retains this
explanation. Unrelated edits, including changes elsewhere in a contract file,
do not invalidate the predicate. No new shaping pass occurs after Build starts.

Existing Intents without recorded predicates remain usable. Shapers should record
product boundaries and shared contracts they actually rely on; broad implementation
file snapshots are unsuitable substitutes for those contracts.
