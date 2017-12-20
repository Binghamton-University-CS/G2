{-# LANGUAGE FlexibleContexts #-}

-- | Reduction Rules for Stack Execution Semantics
module G2.Internals.Execution.Rules
  ( module G2.Internals.Execution.RuleTypes
  , Rule (..)
  , isExecValueForm
  , reduce
  , reduceNoConstraintChecks
  ) where

import G2.Internals.Execution.NormalForms
import G2.Internals.Execution.RuleTypes
import G2.Internals.Language
import qualified G2.Internals.Language.PathConds as PC
import qualified G2.Internals.Language.Stack as S
import qualified G2.Internals.Language.ExprEnv as E
import G2.Internals.Solver.Interface
import G2.Internals.Solver.Language hiding (Assert)

import Control.Monad
import Data.Maybe

-- | Rename multiple things at once with [(olds, news)] on a `Renameable`.
renames :: Named a => [(Name, Name)] -> a -> a
renames n a = foldr (\(old, new) -> rename old new) a n

-- | Inject binds into the eenv. The LHS of the [(Id, Expr)] are treated as
-- seed values for the names.
liftBinds :: [(Id, Expr)] -> E.ExprEnv -> Expr -> NameGen ->
             (E.ExprEnv, Expr, NameGen)
liftBinds binds eenv expr ngen = (eenv', expr', ngen')
  where
    (bindsLHS, bindsRHS) = unzip binds

    olds = map (idName) bindsLHS
    (news, ngen') = freshSeededNames olds ngen
    expr' = renames (zip olds news) expr
    bindsLHS' = renames (zip olds news) bindsLHS

    binds' = zip bindsLHS' bindsRHS

    eenv' = E.insertExprs (zip news (map snd binds')) eenv

-- Due to recursion, Let bindings have to rename the RHS of the bindings
liftLetBinds :: [(Id, Expr)] -> E.ExprEnv -> Expr -> NameGen ->
             (E.ExprEnv, Expr, NameGen)
liftLetBinds binds eenv expr ngen = (eenv', expr', ngen')
  where
    olds = map (idName . fst) binds
    (news, ngen') = freshSeededNames olds ngen
    expr' = renames (zip olds news) expr
    binds' = renames (zip olds news) binds

    eenv' = E.insertExprs (zip news (map snd binds')) eenv

-- | `DataCon` `Alt`s.
dataAlts :: [Alt] -> [(DataCon, [Id], Expr)]
dataAlts alts = [(dcon, ps, aexpr) | Alt (DataAlt dcon ps) aexpr <- alts]

-- | `Lit` `Alt`s.
litAlts :: [Alt] -> [(Lit, Expr)]
litAlts alts = [(lit, aexpr) | Alt (LitAlt lit) aexpr <- alts]

-- | DEFAULT `Alt`s.
defaultAlts :: [Alt] -> [Alt]
defaultAlts alts = [a | a @ (Alt Default _) <- alts]

-- | Match data constructor based `Alt`s.
matchDataAlts :: DataCon -> [Alt] -> [Alt]
matchDataAlts (PrimCon p) alts =
  [a | a @ (Alt (DataAlt (PrimCon p') _) _) <- alts, p == p']
matchDataAlts (DataCon n _ _) alts =
  [a | a @ (Alt (DataAlt (DataCon n' _ _) _) _) <- alts, n == n']

-- | Match literal constructor based `Alt`s.
matchLitAlts :: Lit -> [Alt] -> [Alt]
matchLitAlts lit alts = [a | a @ (Alt (LitAlt alit) _) <- alts, lit == alit]

-- | Lift positive datacon `State`s from symbolic alt matching. This in
-- part involves erasing all of the parameters from the environment by rename
-- their occurrence in the aexpr to something fresh.
liftSymDataAlt :: E.ExprEnv -> Expr -> NameGen -> Id -> [(DataCon, [Id], Expr)] -> [EvaluateResult]
liftSymDataAlt eenv mexpr ngen cvar = map (liftSymDataAlt' eenv mexpr ngen cvar)

liftSymDataAlt' :: E.ExprEnv -> Expr -> NameGen -> Id -> (DataCon, [Id], Expr) -> EvaluateResult
liftSymDataAlt' eenv mexpr ngen cvar (dcon, params, aexpr) = res
  where
    -- Condition that was matched.
    cond = AltCond (DataAlt dcon params) mexpr True

    -- Make sure that the parameters do not conflict in their symbolic reps.
    olds = map idName params
    -- [ChildrenNames]
    -- Optimization
    -- We use the same names repeatedly for the children of the same ADT
    -- Haskell is purely functional, so this is OK!  The children can't change
    -- Then, in the constraint solver, we can consider fewer constraints at once
    -- (see note [AltCond] in Language/PathConds.hs) 
    (news, ngen') = case exprInCasts mexpr of
        (Var (Id n _)) -> childrenNames n olds ngen
        _ -> freshSeededNames olds ngen

    -- (news, ngen') = freshSeededNames olds ngen

    --Update the expr environment
    newIds = map (\(Id _ t, n) -> (n, Id n t)) (zip params news)
    eenv' = foldr (uncurry E.insertSymbolic) eenv newIds

    (cond', aexpr') = renames (zip olds news) (cond, aexpr)

    -- Now do a round of rename for binding the cvar.
    binds = [(cvar, mexpr)]
    (eenv'', aexpr'', ngen'') = liftBinds binds eenv' aexpr' ngen'
    res = ( eenv''
          , CurrExpr Evaluate aexpr''
          , [cond']
          , ngen''
          , Nothing)

liftSymLitAlt :: E.ExprEnv -> Expr -> NameGen -> Id -> [(Lit, Expr)] -> [EvaluateResult]
liftSymLitAlt eenv mexpr ngen cvar = map (liftSymLitAlt' eenv mexpr ngen cvar)

-- | Lift literal alts found in symbolic case matching.
liftSymLitAlt' :: E.ExprEnv -> Expr -> NameGen -> Id -> (Lit, Expr) -> EvaluateResult
liftSymLitAlt' eenv mexpr ngen cvar (lit, aexpr) = res
  where
    -- Condition that was matched.
    cond = AltCond (LitAlt lit) mexpr True
    -- Bind the cvar.
    binds = [(cvar, Lit lit)]
    (eenv', aexpr', ngen') = liftBinds binds eenv aexpr ngen
    res = ( eenv'
          , CurrExpr Evaluate aexpr'
          , [cond]
          , ngen'
          , Nothing)

liftSymDefAlt :: E.ExprEnv -> Expr -> NameGen ->  Id -> [Alt] -> [EvaluateResult]
liftSymDefAlt eenv mexpr ngen cvar as =
    let
        aexpr = defAltExpr as
    in
    case aexpr of
        Just aexpr' -> liftSymDefAlt' eenv mexpr aexpr' ngen cvar as
        _ -> []

liftSymDefAlt' :: E.ExprEnv -> Expr -> Expr -> NameGen ->  Id -> [Alt] -> [EvaluateResult]
liftSymDefAlt' eenv mexpr aexpr ngen cvar as =
    let
        conds = mapMaybe (liftSymDefAltPCs mexpr) (map altMatch as)

        binds = [(cvar, mexpr)]
        (eenv', aexpr', ngen') = liftBinds binds eenv aexpr ngen
    in
    [( eenv'
     , CurrExpr Evaluate aexpr'
     , conds
     , ngen'
     , Nothing)]

defAltExpr :: [Alt] -> Maybe Expr
defAltExpr [] = Nothing
defAltExpr (Alt Default e:_) = Just e
defAltExpr (_:xs) = defAltExpr xs

liftSymDefAltPCs :: Expr -> AltMatch -> Maybe PathCond
liftSymDefAltPCs mexpr (DataAlt dc _) = Just $ ConsCond dc mexpr False
liftSymDefAltPCs mexpr lit@(LitAlt _) = Just $ AltCond lit mexpr False
liftSymDefAltPCs _ Default = Nothing

-- | Attempts to reduce all Vars from the eenv.
varReduce :: (ASTContainer e Expr) => E.ExprEnv -> e -> e
varReduce eenv = modifyASTs (varReduce' eenv)

varReduce' :: E.ExprEnv -> Expr -> Expr
varReduce' eenv v@(Var (Id n _)) =
    if E.isSymbolic n eenv then
        v
    else
        fromMaybe v $ return . varReduce eenv =<< E.lookup n eenv

varReduce' _ e = e

-- | Trace the type contained in an expression of type TYPE.
traceTYPE :: Expr -> E.ExprEnv -> Type
traceTYPE (Var (Id n TYPE)) eenv = case E.lookup n eenv of
    Just (Type res) -> res
    Just expr -> traceTYPE expr eenv
    Nothing -> error "Var of type TYPE not in expression environment."
traceTYPE expr _ = typeOf expr

-- | Function for performing rule reductions based on stack based evaluation
-- semantics with heap memoization.

-- The semantics differ a bit from SSTG a bit, namely in what is and is not
-- returned from the heap. In SSTG, you return either literals or pointers.
-- The distinction is less clear here. For now :)
reduce :: SMTConverter ast out io -> io -> State -> IO (Rule, [State])
reduce con hpp s = do
    let (rule, res) = reduce' s

    sts <- resultsToState con hpp rule s res

    return (rule, sts)

resultsToState :: SMTConverter ast out io -> io -> Rule -> State -> [ReduceResult] -> IO [State]
resultsToState _ _ _ _ [] = return []
resultsToState con hpp rule s@(State {known_values = kv}) (red@(_, _, pc, asserts, _, _):xs)
    | not (null pc) = do
            --Optimization
            -- We replace the path_conds with only those that are directly
            -- affected by the new path constraints
            -- This allows for more efficient solving, and in some cases may
            -- change an Unknown into a SAT or UNSAT
            -- Switching which of the following two lines is commented turns this on/off
            -- let s'' = s'
            let s'' = s' {path_conds = PC.relevant (known_values s) pc (path_conds s')}

            res <- checkConstraints con hpp s''

            if res == SAT then
                return . (:) s' =<< resultsToState con hpp rule s xs
            else
                resultsToState con hpp rule s xs
    | not (null asserts) && not (true_assert s) = do
        let assertS = s' { path_conds = foldr (PC.insert kv) (path_conds s') asserts, true_assert = True }
        let assertSRel = assertS {path_conds = PC.relevant kv asserts (path_conds assertS)}
        
        let negAssertS = s' {path_conds = foldr (PC.insert kv) (path_conds s') (map PC.negatePC asserts)}
        let negAssertSRel = negAssertS {path_conds = PC.relevant kv asserts (path_conds negAssertS)}

        let potentialS = [(assertS, assertSRel), (negAssertS, negAssertSRel)]

        finalS <- filterM (\(_, s_) -> return . isSat =<< checkConstraints con hpp s_) potentialS
        let finalS' = map fst finalS

        return . (++) finalS' =<< resultsToState con hpp rule s xs
    | otherwise = return . (:) s' =<< resultsToState con hpp rule s xs
    where
        s' = resultToState s red

reduceNoConstraintChecks :: State -> (Rule, [State])
reduceNoConstraintChecks s =
    let
        (rule, res) = reduce' s
    in
    (rule, map (resultToState s) res)

resultToState :: State -> ReduceResult -> State
resultToState s (eenv, cexpr, pc, _, ng, st) =
    s {
        expr_env = eenv
      , curr_expr = cexpr
      , path_conds = foldr (PC.insert (known_values s)) (path_conds s) $ pc
      , name_gen = ng
      , exec_stack = st }

-- | Result of a Evaluate reduction.
type ReduceResult = (E.ExprEnv, CurrExpr, [PathCond], [PathCond], NameGen, S.Stack Frame)

reduce' :: State -> (Rule, [ReduceResult])
reduce' s @ State { exec_stack = estk
                 , expr_env = eenv
                 , curr_expr = cexpr
                 , name_gen = ngen
                 }
  | isExecValueForm s =
      (RuleIdentity, [(eenv, varReduce eenv cexpr, [], [], ngen, estk)])

  | CurrExpr Evaluate expr@(App _ _) <- cexpr
  , (Prim Error _):_ <- unApp expr =
      (RuleError, [(eenv, CurrExpr Return (Prim Error TyBottom), [], [], ngen, S.empty)])

  | CurrExpr Evaluate expr <- cexpr
  , isExprValueForm expr eenv =
      -- Our current thing is a value form, which means we can return it.
      (RuleEvalVal, [(eenv, CurrExpr Return expr, [], [], ngen, estk) ])

  | CurrExpr Evaluate expr <- cexpr =
      let (rule, eval_results) = reduceEvaluate eenv expr ngen
          states = map (\(eenv', cexpr', paths', ngen', f) ->
                        ( eenv'
                        , cexpr'
                        , paths'
                        , []
                        , ngen'
                        , maybe estk (\f' -> S.push f' estk) f))
                       eval_results
      in (rule, states)

  | CurrExpr Return expr <- cexpr
  , Just (AssumeFrame fexpr, estk') <- S.pop estk =
      let cond = ExtCond expr True
      in
         (RuleReturnCAssume, [(eenv, CurrExpr Evaluate fexpr, [cond], [], ngen, estk')])

  | CurrExpr Return expr <- cexpr
  , Just (AssertFrame fexpr, estk') <- S.pop estk =
      let cond = ExtCond expr False
      in
         (RuleReturnCAssert, [(eenv, CurrExpr Evaluate fexpr, [], [cond], ngen, estk')])

  | CurrExpr Return expr <- cexpr
  , Just (f, estk') <- S.pop estk =
      let (rule, (eenv', cexpr', ngen')) = reduceEReturn eenv expr ngen f
      in
        (rule, [(eenv', cexpr', [], [], ngen', estk')])

  | otherwise = (RuleError, [(eenv, cexpr, [], [], ngen, estk)])

-- | Result of a Evaluate reduction.
type EvaluateResult = (E.ExprEnv, CurrExpr, [PathCond], NameGen, Maybe Frame)

-- The semantics differ a bit from SSTG a bit, namely in what is and is not
-- returned from the heap. In SSTG, you return either literals or pointers.
-- The distinction is less clear here. For now :)
reduceEvaluate :: E.ExprEnv -> Expr -> NameGen -> (Rule, [EvaluateResult])
reduceEvaluate eenv (Var v) ngen = case E.lookup (idName v) eenv of
    Just expr ->
      -- If the target in our environment is already a value form, we do not
      -- need to push additional redirects for updating later on.
      if isExprValueForm expr eenv
        then ( RuleEvalVarVal
             , [( eenv
                , CurrExpr Evaluate expr
                , []
                , ngen
                , Nothing)])

        -- If our variable points to something on the heap, we first push the
        -- current name of the variable onto the stack and evaluate the
        -- expression that it points to only if it is not a value. After the
        -- latter is done evaluating, we pop the stack to add a redirection
        -- pointer into the heap.
        else let frame = UpdateFrame (idName v)
             in ( RuleEvalVarNonVal
                , [( eenv
                   , CurrExpr Evaluate expr
                   , []
                   , ngen
                   , Just frame)])
    Nothing -> error "reduceEvaluate: lookup was Nothing"

reduceEvaluate eenv (App fexpr aexpr) ngen =
    -- Push application RHS onto the stack. This is essentially the same as the
    -- original STG rules, but we pretend that every function is (appropriately)
    -- single argument. However one problem is that eenv sharing has a redundant
    -- representation because long `App` chains will all share the same eenv.
    -- However given actual lazy evaluations within Haskell, all the
    -- `ExecExprEnv`s at each frame would really be stored in a single
    -- location on the actual Haskell heap during execution.
    case unApp (App fexpr aexpr) of
        ((Prim prim ty):ar) ->
            let ar' = varReduce eenv ar
            in -- trace ("PRIM " ++ (show (head ar)) ++ "\n" ++ (pprExecEEnvStr eenv)) 
            ( RuleEvalPrimToNorm
                , [( eenv
                   -- This may need to be Evaluate if there are more
                   -- than one redirections.
                   , CurrExpr Evaluate (mkApp (Prim prim ty : ar'))
                   , []
                   , ngen
                   , Nothing)])
        _ ->
            let frame = ApplyFrame aexpr
            in ( RuleEvalApp
               , [( eenv
                  , CurrExpr Evaluate fexpr
                  , []
                  , ngen
                  , Just frame)])

reduceEvaluate eenv (Let binds expr) ngen =
    -- Lift all the let bindings into the environment and continue with eenv
    -- and continue with evaluation of the let expression.
    let (eenv', expr', ngen') = liftLetBinds binds eenv expr ngen
    in ( RuleEvalLet
       , [( eenv'
          , CurrExpr Evaluate expr'
          , []
          , ngen'
          , Nothing)])

reduceEvaluate eenv (Case mexpr cvar alts) ngen =
    reduceCase eenv mexpr cvar alts ngen

reduceEvaluate eenv cast@(Cast e coer) ngen =
    let
        (cast', ngen') = splitCast ngen cast

        frame = CastFrame coer
    in
    case cast /= cast' of
        True ->
            (RuleEvalCastSplit, [( eenv
                                 , CurrExpr Evaluate cast'
                                 , []
                                 , ngen'
                                 , Nothing)])
        False ->
           (RuleEvalCast, [( eenv
                          , CurrExpr Evaluate e
                          , []
                          , ngen
                          , Just frame)])

reduceEvaluate eenv (Assume pre lexpr) ngen =
    let frame = AssumeFrame lexpr
    in (RuleEvalAssume, [( eenv
                         , CurrExpr Evaluate pre
                         , []
                         , ngen
                         , Just frame)])
reduceEvaluate eenv (Assert pre lexpr) ngen =
    let frame = AssertFrame lexpr
    in (RuleEvalAssert, [( eenv
                         , CurrExpr Evaluate pre
                         , []
                         , ngen
                         , Just frame)])

reduceEvaluate eenv c ngen =
    (RuleError, [(eenv, CurrExpr Evaluate c, [], ngen, Nothing)])

-- | Handle the Case forms of Evaluate.
reduceCase :: E.ExprEnv -> Expr -> Id -> [Alt] -> NameGen -> (Rule, [EvaluateResult])
reduceCase eenv mexpr bind alts ngen
  -- | Is the current expression able to match with a literal based `Alt`? If
  -- so, we do the cvar binding, and proceed with evaluation of the body.
  | (Lit lit) <- unsafeElimCast mexpr
  , (Alt (LitAlt _) expr):_ <- matchLitAlts lit alts =
      let binds = [(bind, Lit lit)]
          (eenv', expr', ngen') = liftBinds binds eenv expr ngen
      in ( RuleEvalCaseLit
         , [( eenv'
            , CurrExpr Evaluate expr'
            , []
            , ngen'
            , Nothing)])

  -- Is the current expression able to match a data consturctor based `Alt`?
  -- If so, then we bind all the parameters to the appropriate arguments and
  -- proceed with the evaluation of the `Alt`'s expression. We also make sure
  -- to perform the cvar binding.
  | (Data dcon):ar <- unApp $ unsafeElimCast mexpr
  , ar' <- filter (\e -> case e of { Type _ -> False; _ -> True }) ar
  , (Alt (DataAlt _ params) expr):_ <- matchDataAlts dcon alts
  , length params == length ar' =
      let binds = (bind, mexpr) : zip params ar'
          (eenv', expr', ngen') = liftBinds binds eenv expr ngen
      in ( RuleEvalCaseData
         , [( eenv'
            , CurrExpr Evaluate expr'
            , []
            , ngen'
            , Nothing)] )

  -- | We are not able to match any constructor but don't have a symbolic variable?
  -- We hit a DEFAULT instead.
  -- We perform the cvar binding and proceed with the alt
  -- expression.
  | (Data _):_ <- unApp $ unsafeElimCast mexpr
  , (Alt _ expr):_ <- defaultAlts alts =
      let binds = [(bind, mexpr)]
          (eenv', expr', ngen') = liftBinds binds eenv expr ngen
      in ( RuleEvalCaseDefault
         , [( eenv'
            , CurrExpr Evaluate expr'
            , []
            , ngen'
            , Nothing)])

  -- | If we are pointing to something in expr value form, that is not addressed
  -- by some previous case, we handle it by branching on every `Alt`, and adding
  -- path constraints.
  | isExprValueForm mexpr eenv
  , dalts <- dataAlts alts
  , lalts <- litAlts alts
  , defs <- defaultAlts alts
  , (length dalts + length lalts + length defs) > 0 =
      let
          dsts_cs = liftSymDataAlt eenv mexpr ngen bind dalts
          lsts_cs = liftSymLitAlt eenv mexpr ngen bind lalts
          def_sts = liftSymDefAlt eenv mexpr ngen bind alts
      in
      (RuleEvalCaseSym, dsts_cs ++ lsts_cs ++ def_sts)

  -- Case evaluation also uses the stack in graph reduction based evaluation
  -- semantics. The case's binding variable and alts are pushed onto the stack
  -- as a `CaseFrame` along with their appropriate `ExecExprEnv`. However this
  -- is only done when the matching expression is NOT in value form. Value
  -- forms should be handled by other RuleEvalCase* rules.
  | not (isExprValueForm mexpr eenv) =
      let frame = CaseFrame bind alts
      in ( RuleEvalCaseNonVal
         , [( eenv
            , CurrExpr Evaluate mexpr
            , []
            , ngen
            , Just frame)])

  | otherwise = error $ "reduceCase: bad case passed in\n" ++ show mexpr ++ "\n" ++ show alts

-- | Result of a Return reduction.
type EReturnResult = (E.ExprEnv, CurrExpr, NameGen)

-- | Handle the Return states.
reduceEReturn :: E.ExprEnv -> Expr -> NameGen -> Frame -> (Rule, EReturnResult)

-- We are returning something and the first thing that we have on the stack
-- is an `UpdateFrame`, this means that we add a redirection pointer to the
-- `ExecExprEnv`, and continue with execution. This is the equivalent of
-- performing memoization on values that we have seen.
reduceEReturn eenv (Var (Id name ty)) ngen (UpdateFrame frm_name) =
  ( RuleReturnEUpdateVar
  , ( E.redirect frm_name name eenv
    , CurrExpr Return (Var $ Id name ty)
    , ngen))

-- If the variable we are returning does not have a `Var` in it at the
-- immediate top level, then we have to insert it into the `ExecExprEnv`
-- directly.
reduceEReturn eenv expr ngen (UpdateFrame frm_name) =
  ( RuleReturnEUpdateNonVar
  , ( E.insert frm_name expr eenv
    , CurrExpr Return expr
    , ngen))

-- In the event that we are returning and we have a `CaseFrame` waiting for
-- us at the top of the stack, we would simply inject it into the case
-- expression. We do some assumptions here about the form of expressions!
reduceEReturn eenv expr ngen (CaseFrame cvar alts) =
  ( RuleReturnECase
  , ( eenv
    , CurrExpr Evaluate (Case expr cvar alts)
    , ngen))

-- If we have a `CastFrame` at the top of the stack, we know to recast
-- the Current Expression.
reduceEReturn eenv e ngen (CastFrame (t1 :~ t2)) =
  ( RuleReturnCast
  , ( eenv
    , CurrExpr Evaluate $ Cast e (t1 :~ t2)
    , ngen))

-- In the event that our Lam parameter is a type variable, we have to handle
-- it by retyping.
reduceEReturn eenv (Lam a@(Id n TYPE) lexpr) ngen (ApplyFrame aexpr) =
  let aty = traceTYPE aexpr eenv
      binds = [(Id n aty, aexpr)]
      lexpr' = retype a aty lexpr
      (eenv', lexpr'', ngen') = liftBinds binds eenv lexpr' ngen
  in ( RuleReturnEApplyLamType
     , ( eenv'
       , CurrExpr Evaluate lexpr''
       , ngen'))

-- When we have an `ApplyFrame` on the top of the stack, things might get a
-- bit tricky, since we need to make sure that the thing we end up returning
-- is appropriately a value. In the case of `Lam`, we need to perform
-- application, and then go into the expression body.
reduceEReturn eenv (Lam b lexpr) ngen (ApplyFrame aexpr) =
  let binds = [(b, aexpr)]
      (eenv', lexpr', ngen') = liftBinds binds eenv lexpr ngen
  in ( RuleReturnEApplyLamExpr
     , ( eenv'
       , CurrExpr Evaluate lexpr'
       , ngen'))

-- When we return symbolic values on an `ApplyFrame`, introduce new name
-- mappings in the eenv to form this long symbolic normal form chain.
reduceEReturn eenv c@(Var v) ngen (ApplyFrame aexpr) =
  if not (E.isSymbolic (idName v) eenv)
    then (RuleError, (eenv, CurrExpr Return c, ngen))
    else let (sname, ngen') = freshSeededName (idName v) ngen
             sym_app = App (Var v) aexpr
             svar = Id sname (mkTyApp (typeOf v) (typeOf aexpr))
         in ( RuleReturnEApplySym
            , ( E.insert sname sym_app eenv
              , CurrExpr Return (Var svar)
              , ngen'))
reduceEReturn eenv c ngen (ApplyFrame aexpr) =
  case unApp c of
      p@(Prim _ _):_ ->  
          ( RuleReturnEApplySym
          , ( eenv
            , CurrExpr Evaluate (App c aexpr)
            , ngen))
      _ -> (RuleError, (eenv, CurrExpr Return c, ngen))

reduceEReturn eenv c ngen _ = (RuleError, (eenv, CurrExpr Return c, ngen))

