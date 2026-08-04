[
  import_deps: [:ash, :ash_postgres, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,scripts,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter]
]
