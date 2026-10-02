Mimic.copy(Ecto.Adapters.SQL)

# The tests that reach real services, which dev/services.sh starts, are
# left out where nothing answers; see WardrikEcto.Test.Services.
Wardrik.Test.start(exclude: WardrikEcto.Test.Services.start())
