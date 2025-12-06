%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "test/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/test/",
          "apps/*/web/"
        ],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/",
          # Exclude generated test support files from some checks
          ~r"/test/support/data_case\.ex$/",
          ~r"/test/support/conn_case\.ex$/"
        ]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          #
          ## Consistency Checks
          #
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          #
          ## Design Checks
          #
          {Credo.Check.Design.AliasUsage,
           [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 0]},
          # TODOs should be addressed - exit with error
          {Credo.Check.Design.TagTODO, [exit_status: 2]},
          {Credo.Check.Design.TagFIXME, [exit_status: 2]},
          # Detect duplicated code blocks
          {Credo.Check.Design.DuplicatedCode, [mass_threshold: 30, nodes_threshold: 2]},
          # Require comment when skipping tests
          {Credo.Check.Design.SkipTestWithoutComment, []},

          #
          ## Readability Checks
          #
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithSingleClause, []},
          # Encourage pipelines over nested function calls
          {Credo.Check.Readability.NestedFunctionCalls, [min_pipeline_length: 3]},

          #
          ## Refactoring Opportunities
          #
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Refactor.CondStatements, []},
          # Strict cyclomatic complexity limit
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 10]},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          # Limit function arity
          {Credo.Check.Refactor.FunctionArity, [max_arity: 6]},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          # Strict nesting limit
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},
          # Limit module dependencies to reduce coupling
          {Credo.Check.Refactor.ModuleDependencies, [max_deps: 20]},
          # ABC complexity metric
          {Credo.Check.Refactor.ABCSize, [max_size: 50]},
          # Detect inefficient list appends
          {Credo.Check.Refactor.AppendSingleItem, []},
          # Simplify double boolean negation
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          # Detect filter followed by reject (use one or the other)
          {Credo.Check.Refactor.FilterReject, []},
          # Detect reject followed by filter
          {Credo.Check.Refactor.RejectFilter, []},
          # Simplify negated is_nil checks
          {Credo.Check.Refactor.NegatedIsNil, []},

          #
          ## Warnings
          #
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFileExtension, []},
          # Detect environment variable leaks
          {Credo.Check.Warning.LeakyEnvironment, []},
          # Warn on unsafe Map.get with nil default
          {Credo.Check.Warning.MapGetUnsafePass, []},
          # Detect Mix.env() usage at runtime
          {Credo.Check.Warning.MixEnv, []},
          # Warn on String.to_atom with user input
          {Credo.Check.Warning.UnsafeToAtom, []}
        ],
        disabled: [
          # These are genuinely controversial/not applicable:

          # LazyLogging requires Elixir < 1.7.0
          {Credo.Check.Warning.LazyLogging, []},
          # MultiAliasImportRequireUse is too strict for mixed codebases
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          # UnusedVariableNames - both `_` and `_foo` are valid
          {Credo.Check.Consistency.UnusedVariableNames, []},
          # ImplTrue requiring specific behaviour is too strict
          {Credo.Check.Readability.ImplTrue, []},
          # AliasAs is too opinionated
          {Credo.Check.Readability.AliasAs, []},
          # SeparateAliasRequire is noisy
          {Credo.Check.Readability.SeparateAliasRequire, []},
          # StrictModuleLayout is too disruptive for existing codebases
          {Credo.Check.Readability.StrictModuleLayout, []},
          # PassAsyncInTestCases - async is a convention choice
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          # BlockPipe can conflict with other pipe rules
          {Credo.Check.Readability.BlockPipe, []},
          # MultiAlias is a style preference, we use MultiAliasImportRequireUse instead
          {Credo.Check.Readability.MultiAlias, []},
          # OnePipePerLine is too strict for most codebases
          {Credo.Check.Readability.OnePipePerLine, []},
          # SingleFunctionToBlockPipe conflicts with other rules
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          # SinglePipe is controversial - short pipes are fine
          {Credo.Check.Readability.SinglePipe, []},
          # Specs are enforced by Dialyzer, not Credo
          {Credo.Check.Readability.Specs, []},
          # WithCustomTaggedTuple is too opinionated
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          # IoPuts is fine in scripts
          {Credo.Check.Refactor.IoPuts, []},
          # MapMap can be intentional
          {Credo.Check.Refactor.MapMap, []},
          # PipeChainStart is controversial
          {Credo.Check.Refactor.PipeChainStart, []},
          # Variable rebinding is idiomatic in Elixir
          {Credo.Check.Refactor.VariableRebinding, []}
        ]
      }
    }
  ]
}
