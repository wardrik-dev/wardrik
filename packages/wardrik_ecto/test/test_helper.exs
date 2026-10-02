Mimic.copy(Ecto.Adapters.SQL)

# The tests that reach real services, which dev/services.sh starts, are
# left out where nothing answers; see Wardrik.Test.Services.
Wardrik.Test.start(exclude: Wardrik.Test.Services.start())
