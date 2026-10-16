# Duplication policy for `mix ex_dna`.
#
# Each operation module implements a domain behaviour (who it acts on) and an
# effect behaviour (what it does), so modules acting on the same subject with
# the same action open with the same few callbacks: subject/1, action/0, and
# a plan whose effect is the request. Those parallel implementations are the
# design, and clone detection reads them as copies.
%{ignore: ["lib/wardrik/operations/**"]}
