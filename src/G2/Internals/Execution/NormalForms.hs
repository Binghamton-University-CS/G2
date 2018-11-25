module G2.Internals.Execution.NormalForms where

import G2.Internals.Language
import qualified G2.Internals.Language.Stack as S
import qualified G2.Internals.Language.ExprEnv as E

-- | If something is in "value form", then it is essentially ready to be
-- returned and popped off the heap. This will be the SSTG equivalent of having
-- Return vs Evaluate for the ExecCode of the `State`.
--
-- So in this context, the following are considered NOT-value forms:
--   `Var`, only if a lookup still available in the expression environment.
--   `App`, which involves pushing the RHS onto the `Stack`, if the center is not a Prim or DataCon
--   `Let`, which involves binding the binds into the eenv
--   `Case`, which involves pattern decomposition and stuff.
isExprValueForm :: Expr -> E.ExprEnv -> Bool
isExprValueForm (Var var) eenv =
    E.lookup (idName var) eenv == Nothing || E.isSymbolic (idName var) eenv
isExprValueForm (App f a) eenv = case unApp (App f a) of
    (Prim _ _:xs) -> all (flip isExprValueForm eenv) xs
    (Data _:_) -> True
    ((Var _):_) -> False
    _ -> False
isExprValueForm (Let _ _) _ = False
isExprValueForm (Case _ _ _) _ = False
isExprValueForm (Cast e (t :~ _)) eenv = not (hasFuncType t) && isExprValueForm e eenv
isExprValueForm (SymGen _) _ = False
isExprValueForm (Assume _ _) _ = False
isExprValueForm (Assert _ _ _) _ = False
isExprValueForm _ _ = True

-- | Is the execution state in a value form of some sort? This would entail:
-- * The `Stack` is empty.
-- * The `ExecCode` is in a `Return` form.
-- * We have no path conds to reduce
isExecValueForm :: State t -> Bool
isExecValueForm state | Nothing <- S.pop (exec_stack state)
                      , CurrExpr Return _ <- curr_expr state
                      , non_red_path_conds state == [] = True
                      | otherwise = False


isExecValueFormDisNonRedPC :: State t -> Bool
isExecValueFormDisNonRedPC s = isExecValueForm $ s {non_red_path_conds = []}
