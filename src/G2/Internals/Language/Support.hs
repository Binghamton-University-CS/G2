{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module G2.Internals.Language.Support
    ( module G2.Internals.Language.ArbValueGen
    , module G2.Internals.Language.AST
    , module G2.Internals.Language.Support
    , module G2.Internals.Language.TypeEnv
    , AT.ApplyTypes
    , E.ExprEnv
    , KnownValues
    , PathCond (..)
    , Constraint
    , Assertion
    , SymLinks
    ) where

import qualified G2.Internals.Language.ApplyTypes as AT
import G2.Internals.Language.ArbValueGen
import G2.Internals.Language.AST
import qualified G2.Internals.Language.ExprEnv as E
import G2.Internals.Language.KnownValues
import G2.Internals.Language.Naming
import G2.Internals.Language.Stack
import G2.Internals.Language.SymLinks hiding (filter, map)
import G2.Internals.Language.Syntax
import G2.Internals.Language.TypeClasses
import G2.Internals.Language.TypeEnv
import G2.Internals.Language.PathConds hiding (map)
import G2.Internals.Execution.RuleTypes

import qualified Data.Map as M
import qualified Data.HashMap.Lazy as HM
import qualified Data.Text as T

-- | The State is something that is passed around in G2. It can be utilized to
-- perform defunctionalization, execution, and SMT solving.
-- track can be used to collect some extra information for the end of execution.
-- drop is used to help determine if a state that has not reached RuleIndentity
-- should continue execution anyway.
-- The h parameter is used to help track whether reduce should continue executing
-- a state or not
-- The t parameter can be used to track extra information during the execution.
data State h t = State { expr_env :: E.ExprEnv
                       , type_env :: TypeEnv
                       , curr_expr :: CurrExpr
                       , name_gen :: NameGen
                       , path_conds :: PathConds
                       , true_assert :: Bool
                       , assert_ids :: Maybe FuncCall
                       , type_classes :: TypeClasses
                       , sym_links :: SymLinks
                       , input_ids :: InputIds
                       , symbolic_ids :: SymbolicIds
                       , func_table :: FuncInterps
                       , deepseq_walkers :: Walkers
                       , apply_types :: AT.ApplyTypes
                       , exec_stack :: Stack Frame
                       , model :: Model
                       , arbValueGen :: ArbValueGen
                       , known_values :: KnownValues
                       , cleaned_names :: CleanedNames
                       , rules :: [Rule]
                       , halter :: h
                       , track :: t
                       } deriving (Show, Eq, Read)

-- | The InputIds are a list of the variable names passed as input to the
-- function being symbolically executed
type InputIds = [Id]

-- | The SmbolicIds are a list of the variable names that we should ensure are
-- inserted in the model, after we solve the path constraints
type SymbolicIds = [Id]

-- | `CurrExpr` is the current expression we have. We are either evaluating it, or
-- it is in some terminal form that is simply returned. Technically we do not
-- need to make this distinction and can simply call a `isTerm` function or
-- equivalent to check, but this makes clearer distinctions for writing the
-- evaluation code.
data EvalOrReturn = Evaluate
                  | Return
                  deriving (Show, Eq, Read)

data CurrExpr = CurrExpr EvalOrReturn Expr
              deriving (Show, Eq, Read)

-- | Function interpretation table.
-- Maps ADT constructors representing functions to their interpretations.
newtype FuncInterps = FuncInterps (M.Map Name (Name, Interp))
                    deriving (Show, Eq, Read)

-- | Functions can have a standard interpretation or be uninterpreted.
data Interp = StdInterp | UnInterp deriving (Show, Eq, Read)

-- Used to map names (typically of ADTs) to corresponding autogenerated function names
type Walkers = M.Map Name Id

-- Map new names to old ones
type CleanedNames = M.Map Name Name

-- | Naive expression lookup by only the occurrence name string.
naiveLookup :: T.Text -> E.ExprEnv -> [(Name, Expr)]
naiveLookup key = filter (\(Name occ _ _ _, _) -> occ == key) . E.toExprList

emptyFuncInterps :: FuncInterps
emptyFuncInterps = FuncInterps M.empty

-- | Do some lookups into the function interpretation table.
lookupFuncInterps :: Name -> FuncInterps -> Maybe (Name, Interp)
lookupFuncInterps name (FuncInterps fs) = M.lookup name fs

-- | Add some items into the function interpretation table.
insertFuncInterps :: Name -> (Name, Interp) -> FuncInterps -> FuncInterps
insertFuncInterps fun int (FuncInterps fs) = FuncInterps (M.insert fun int fs)

-- | You can also join function interpretation tables
-- Note: only reasonable if the union of their key set all map to the same elements.
unionFuncInterps :: FuncInterps -> FuncInterps -> FuncInterps
unionFuncInterps (FuncInterps fs1) (FuncInterps fs2) = FuncInterps $ M.union fs1 fs2

-- | The reason that Haskell does not enable stack traces by default is because
-- the notion of a function call stack does not really exist in Haskell. The
-- stack is a combination of update pointers, application frames, and other
-- stuff!
-- newtype Stack = Stack [Frame] deriving (Show, Eq, Read)

-- | These are stack frames.
-- * Case frames contain an `Id` for which to bind the inspection expression,
--     a list of `Alt`, and a `ExecExprEnv` in which this `CaseFrame` happened.
--     `CaseFrame`s are generated as a result of evaluating `Case` expressions.
-- * Application frames contain a single expression and its `ExecExprEnv`.
--     These are generated by `App` expressions.
-- * Update frames contain the `Name` on which to inject a new thing into the
--     expression environment after the current expression is done evaluating.
data Frame = CaseFrame Id [Alt]
           | ApplyFrame Expr
           | UpdateFrame Name
           | CastFrame Coercion
           | AssumeFrame Expr
           | AssertFrame (Maybe FuncCall) Expr
           deriving (Show, Eq, Read)

type Model = M.Map Name Expr

-- | Replaces all of the names old in state with a name seeded by new_seed
renameState :: (Named h, Named t) => Name -> Name -> State h t -> State h t
renameState old new_seed s =
    let (new, ng') = freshSeededName new_seed (name_gen s)
    in State { expr_env = rename old new (expr_env s)
             , type_env =
                  M.mapKeys (\k -> if k == old then new else k)
                  $ rename old new (type_env s)
             , curr_expr = rename old new (curr_expr s)
             , name_gen = ng'
             , path_conds = rename old new (path_conds s)
             , true_assert = true_assert s
             , assert_ids = rename old new (assert_ids s)
             , type_classes = rename old new (type_classes s)
             , input_ids = rename old new (input_ids s)
             , symbolic_ids = rename old new (symbolic_ids s)
             , sym_links = rename old new (sym_links s)
             , func_table = rename old new (func_table s)
             , apply_types = rename old new (apply_types s)
             , deepseq_walkers = rename old new (deepseq_walkers s)
             , exec_stack = exec_stack s
             , model = model s
             , arbValueGen = arbValueGen s
             , known_values = rename old new (known_values s)
             , cleaned_names = M.insert new old (cleaned_names s)
             , rules = rules s
             , halter = rename old new (halter s)
             , track = rename old new (track s) }

instance {-# OVERLAPPING #-} (Named h, Named t) => Named (State h t) where
    names s = names (expr_env s)
            ++ names (type_env s)
            ++ names (curr_expr s)
            ++ names (path_conds s)
            ++ names (assert_ids s)
            ++ names (type_classes s)
            ++ names (input_ids s)
            ++ names (symbolic_ids s)
            ++ names (sym_links s)
            ++ names (func_table s)
            ++ names (apply_types s)
            ++ names (deepseq_walkers s)
            ++ names (exec_stack s)
            ++ names (model s)
            ++ names (known_values s)
            ++ names (cleaned_names s)
            ++ names (halter s)
            ++ names (track s)

    rename old new s =
        State { expr_env = rename old new (expr_env s)
               , type_env =
                    M.mapKeys (\k -> if k == old then new else k)
                    $ rename old new (type_env s)
               , curr_expr = rename old new (curr_expr s)
               , name_gen = name_gen s
               , path_conds = rename old new (path_conds s)
               , true_assert = true_assert s
               , assert_ids = rename old new (assert_ids s)
               , type_classes = rename old new (type_classes s)
               , input_ids = rename old new (input_ids s)
               , symbolic_ids = rename old new (symbolic_ids s)
               , sym_links = rename old new (sym_links s)
               , func_table = rename old new (func_table s)
               , apply_types = rename old new (apply_types s)
               , deepseq_walkers = rename old new (deepseq_walkers s)
               , exec_stack = rename old new (exec_stack s)
               , model = rename old new (model s)
               , arbValueGen = arbValueGen s
               , known_values = rename old new (known_values s)
               , cleaned_names = M.insert new old (cleaned_names s)
               , rules = rules s
               , halter = rename old new (halter s)
               , track = rename old new (track s) }

    renames hm s =
        State { expr_env = renames hm (expr_env s)
               , type_env =
                    M.mapKeys (renames hm)
                    $ renames hm (type_env s)
               , curr_expr = renames hm (curr_expr s)
               , name_gen = name_gen s
               , path_conds = renames hm (path_conds s)
               , true_assert = true_assert s
               , assert_ids = renames hm (assert_ids s)
               , type_classes = renames hm (type_classes s)
               , input_ids = renames hm (input_ids s)
               , symbolic_ids = renames hm (symbolic_ids s)
               , sym_links = renames hm (sym_links s)
               , func_table = renames hm (func_table s)
               , apply_types = renames hm (apply_types s)
               , deepseq_walkers = renames hm (deepseq_walkers s)
               , exec_stack = renames hm (exec_stack s)
               , model = renames hm (model s)
               , arbValueGen = arbValueGen s
               , known_values = renames hm (known_values s)
               , cleaned_names = foldr (uncurry M.insert) (cleaned_names s) (HM.toList hm)
               , rules = rules s
               , halter = renames hm (halter s)
               , track = renames hm (track s) }

-- | TypeClass definitions
instance {-# OVERLAPPING #-} (ASTContainer h Expr, ASTContainer t Expr) => ASTContainer (State h t) Expr where
    containedASTs s = (containedASTs $ type_env s) ++
                      (containedASTs $ expr_env s) ++
                      (containedASTs $ curr_expr s) ++
                      (containedASTs $ path_conds s) ++
                      (containedASTs $ assert_ids s) ++
                      (containedASTs $ sym_links s) ++
                      (containedASTs $ input_ids s) ++
                      (containedASTs $ symbolic_ids s) ++
                      (containedASTs $ exec_stack s) ++
                      (containedASTs $ halter s) ++
                      (containedASTs $ track s)

    modifyContainedASTs f s = s { type_env  = modifyContainedASTs f $ type_env s
                                , expr_env  = modifyContainedASTs f $ expr_env s
                                , curr_expr = modifyContainedASTs f $ curr_expr s
                                , path_conds = modifyContainedASTs f $ path_conds s
                                , assert_ids = modifyContainedASTs f $ assert_ids s
                                , sym_links = modifyContainedASTs f $ sym_links s
                                , input_ids = modifyContainedASTs f $ input_ids s
                                , symbolic_ids = modifyContainedASTs f $ symbolic_ids s
                                , exec_stack = modifyContainedASTs f $ exec_stack s
                                , halter = modifyContainedASTs f $ halter s
                                , track = modifyContainedASTs f $ track s }


instance {-# OVERLAPPING #-} (ASTContainer d Type, ASTContainer t Type) => ASTContainer (State d t) Type where
    containedASTs s = ((containedASTs . expr_env) s) ++
                      ((containedASTs . type_env) s) ++
                      ((containedASTs . curr_expr) s) ++
                      ((containedASTs . path_conds) s) ++
                      ((containedASTs . assert_ids) s) ++
                      ((containedASTs . type_classes) s) ++
                      ((containedASTs . sym_links) s) ++
                      ((containedASTs . input_ids) s) ++
                      ((containedASTs . symbolic_ids) s) ++
                      ((containedASTs . exec_stack) s) ++
                      ((containedASTs . halter) s) ++
                      (containedASTs $ track s)

    modifyContainedASTs f s = s { type_env  = (modifyContainedASTs f . type_env) s
                                , expr_env  = (modifyContainedASTs f . expr_env) s
                                , curr_expr = (modifyContainedASTs f . curr_expr) s
                                , path_conds = (modifyContainedASTs f . path_conds) s
                                , assert_ids = (modifyContainedASTs f . assert_ids) s
                                , type_classes = (modifyContainedASTs f . type_classes) s
                                , sym_links = (modifyContainedASTs f . sym_links) s
                                , input_ids = (modifyContainedASTs f . input_ids) s
                                , symbolic_ids = (modifyContainedASTs f . symbolic_ids) s
                                , exec_stack = (modifyContainedASTs f . exec_stack) s
                                , halter = (modifyContainedASTs f . halter) s
                                , track = modifyContainedASTs f $ track s }

instance ASTContainer CurrExpr Expr where
    containedASTs (CurrExpr _ e) = [e]
    modifyContainedASTs f (CurrExpr er e) = CurrExpr er (f e)

instance ASTContainer CurrExpr Type where
    containedASTs (CurrExpr _ e) = containedASTs e
    modifyContainedASTs f (CurrExpr er e) = CurrExpr er (modifyContainedASTs f e)

instance ASTContainer Frame Expr where
    containedASTs (CaseFrame _ a) = containedASTs a
    containedASTs (ApplyFrame e) = [e]
    containedASTs (AssumeFrame e) = [e]
    containedASTs (AssertFrame _ e) = [e]
    containedASTs _ = []

    modifyContainedASTs f (CaseFrame i a) = CaseFrame i (modifyContainedASTs f a)
    modifyContainedASTs f (ApplyFrame e) = ApplyFrame (f e)
    modifyContainedASTs f (AssumeFrame e) = AssumeFrame (f e)
    modifyContainedASTs f (AssertFrame is e) = AssertFrame is (f e)
    modifyContainedASTs _ fr = fr

instance ASTContainer Frame Type where
    containedASTs (CaseFrame i a) = containedASTs i ++ containedASTs a
    containedASTs (ApplyFrame e) = containedASTs e
    containedASTs (AssumeFrame e) = containedASTs e
    containedASTs (AssertFrame _ e) = containedASTs e
    containedASTs _ = []

    modifyContainedASTs f (CaseFrame i a) =
        CaseFrame (modifyContainedASTs f i) (modifyContainedASTs f a)
    modifyContainedASTs f (ApplyFrame e) = ApplyFrame (modifyContainedASTs f e)
    modifyContainedASTs f (AssumeFrame e) = AssumeFrame (modifyContainedASTs f e)
    modifyContainedASTs f (AssertFrame is e) = AssertFrame (modifyContainedASTs f is) (modifyContainedASTs f e)
    modifyContainedASTs _ fr = fr

instance Named CurrExpr where
    names (CurrExpr _ e) = names e
    rename old new (CurrExpr er e) = CurrExpr er $ rename old new e
    renames hm (CurrExpr er e) = CurrExpr er $ renames hm e

instance Named FuncInterps where
    names (FuncInterps m) = M.keys m ++ (map fst $ M.elems m) 

    rename old new (FuncInterps m) =
        FuncInterps . M.mapKeys (rename old new) . M.map (\(n, i) -> (rename old new n, i)) $ m

    renames hm (FuncInterps m) =
        FuncInterps . M.mapKeys (renames hm) . M.map (\(n, i) -> (renames hm n, i)) $ m

instance Named Frame where
    names (CaseFrame i a) = names i ++ names a
    names (ApplyFrame e) = names e
    names (UpdateFrame n) = [n]
    names (CastFrame c) = names c
    names (AssumeFrame e) = names e
    names (AssertFrame is e) = names is ++ names e

    rename old new (CaseFrame i a) = CaseFrame (rename old new i) (rename old new a)
    rename old new (ApplyFrame e) = ApplyFrame (rename old new e)
    rename old new (UpdateFrame n) = UpdateFrame (rename old new n)
    rename old new (CastFrame c) = CastFrame (rename old new c)
    rename old new (AssumeFrame e) = AssumeFrame (rename old new e)
    rename old new (AssertFrame is e) = AssertFrame (rename old new is) (rename old new e)

    renames hm (CaseFrame i a) = CaseFrame (renames hm i) (renames hm a)
    renames hm (ApplyFrame e) = ApplyFrame (renames hm e)
    renames hm (UpdateFrame n) = UpdateFrame (renames hm n)
    renames hm (CastFrame c) = CastFrame (renames hm c)
    renames hm (AssumeFrame e) = AssumeFrame (renames hm e)
    renames hm (AssertFrame is e) = AssertFrame (renames hm is) (renames hm e)
