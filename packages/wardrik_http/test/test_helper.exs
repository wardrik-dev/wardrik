# A holder that outlives its revocation is killed after a twentieth of a
# second rather than a second.
Wardrik.Test.start(children: [{WardrikHTTP.Access, grace: 50}, WardrikHTTP.Workers])
