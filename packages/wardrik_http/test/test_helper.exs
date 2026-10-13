# A holder that outlives its revocation is killed after a twentieth of a
# second rather than a second.
Wardrik.Test.start(
  children: [{WardrikHTTP.Access, store: Wardrik.Test.store(), grace: 50}, WardrikHTTP.Workers]
)
