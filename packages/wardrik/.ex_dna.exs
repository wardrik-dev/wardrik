# Duplication policy for `mix ex_dna`.
#
# The Postgres and S3 stores implement WardrikStore.Adapter the same way, each
# by handing every callback to its own module's function of that name. The
# delegations are the protocol's shape, and clone detection reads them as
# copies.
%{ignore: ["lib/wardrik_ecto/store.ex", "lib/wardrik_s3/store.ex"]}
