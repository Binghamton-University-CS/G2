-- | Language
--   Provides the language definition of G2. Should not be confused with Core
--   Haskell, although design imitates Core Haskell closely.
module G2.Internals.Core.GenLanguage
    ( module G2.Internals.Core.GenLanguage ) where

import qualified Data.Map as M

-- | Execution State
--   Our execution state consists of several things that we keep track of:
--     1. Type Environment: Contains things such as algebraic data types and
--        functions. We mostly need this to reconstruct data for SMT solvers.
--
--     2. Expression Environment: Maps names (strings) to their corresponding
--        expressions. Functions after currying are represented as a sequence
--        of cascading lambda expressions.
--
--     3. Current Expression: The expression we are trying to evaluate.
--
--     4. Path Constraints: Keep track of which Alt branchings we have taken.
--
--     5. Symbolic Link Table: Maps renamed variables to their original names.
--        If they are a renamed input variable, we store their input position
--        as Just Int, otherwise stored as Nothing.
--
--     6. Function Interpretation Table: Maps the Apply data constructors
--        to their function names.  Interp distinguishes between functions that
--        exist in the expression environment (StdInterp) and those that should
--        be treated as uninterpreted functions (UnInterp)
data GenState n = State { expr_env     :: GenEEnv n
                        , type_env     :: GenTEnv n
                        , curr_expr    :: GenExpr n
                        , path_cons    :: [GenPathCond n]
                        , sym_links    :: GenSymLinkTable n
                        , func_interps :: GenFuncInterpTable n
                        , all_names    :: M.Map n Int
                        } deriving (Show, Eq)



type GenTEnv n = M.Map n (GenType n)

type GenEEnv n = M.Map n (GenExpr n)

type GenSymLinkTable n = M.Map n (n, GenType n, Maybe Int)

type GenFuncInterpTable n = M.Map n (n, Interp)

data Interp = StdInterp | UnInterp deriving (Show, Eq)

-- | Expressions
--   We annotate our expressions with types. The reason we do this is because
--   type information is needed to reconstruct statements for SMT solvers.
--
--     Var    -- Variables.
--     Const  -- Constants, such as Int#, +#, and others.
--     Lam    -- Lambda functions. Its type is a TyFun.
--     App    -- Expression (function) application.
--     Data   -- Data constructors.
--     Case   -- Case expressions. Type denotes the type of its Alts.
--     Type   -- A type expression. Unfortuantely we do need this.
--     Assume -- Assume. The LHS assumes a condition for the RHS.
--     Assert -- Assert. The LHS asserts a condition for the RHS.
--     BAD    -- Error / filler expression.
data GenExpr n = Var n (GenType n)
                 | Const Const
                 | Prim Prim (GenType n)
                 | Lam n (GenExpr n) (GenType n)
                 | Let [(n, (GenExpr n))] (GenExpr n)
                 | App (GenExpr n) (GenExpr n)
                 | Data (GenDataCon n)
                 | Case (GenExpr n) [((GenAlt n), (GenExpr n))] (GenType n)
                 | Type (GenType n)
                 | Assume (GenExpr n) (GenExpr n)
                 | Assert (GenExpr n) (GenExpr n)
                 | BAD
                 deriving (Show, Eq)

-- | Primitives
-- These are used to represent various functions in expressions
-- Translations from functions to these primitives are done
-- in G2.Internals.Core.PrimReplace.  This allows for more general
-- handling in the SMT solver- we are not tied to the specific function
-- names/symbols that come from Haskell
data Prim = PTrue
          | PFalse
          | GE -- >=
          | GrT -- >
          | EQL -- ==
          | LsT -- <
          | LE -- <=
          | And
          | Or
          | Not
          | Implies
          | Plus
          | Minus
          | Mult
          | Div
          deriving (Show, Eq)

-- | Constants
--   Const reflects Haskell's 4 primitive types: Int, Float, Double, and Char.
--
--   We use CString as a way of catching string literals.
--
--   An additional COp is a way to circumvent Haskell functions such as +# that
--   do not have a native Haskell implementation. Since the list of these
--   special functions are limited, it is probably better that we don't try to
--   explicitly give these implementations, and instead leave them as COps and
--   handle them during the SMT solver phase.
data Const = CInt Int         -- Int#
           | CFloat Rational  -- Float#
           | CDouble Rational -- Double#
           | CChar Char       -- Char#
           | CString String
           deriving (Show, Eq)

-- | Data Constructors
--   We keep track of information such as the name, tag (unique integer ID),
--   the corresponding ADT type, and the argument types.
--
--   Note: data constructors can be treated semantically as functions, so if a
--   data constructor constructed type A and had parameters of P1, ..., PN, its
--   function type would be:
--
--     P1 -> P2 -> ... -> PN -> A
--
--   However, it would be represented as:
--
--     (dc_name, dc_tag, A, [P1, ..., PN])
-- newtype DataCon = DC (Name, Int, Type, [Type]) deriving (Show, Eq)
data GenDataCon n = DataCon n Int (GenType n) [GenType n]
                  | DEFAULT
                  deriving (Show, Eq)

-- | Types
--   We need a way of representing types, and so it is done here.
--
--   The TyRaw* types are meant to deal with unwrapped types. For example, Int#
--   would be equivalent to TyRawInt.
--
--   TyApp is a catch-all statement in case we accidentally run into type
--   variables when trying to "type check" a function type's App spine.
--
--   TyConApp is equivalent to applying types to parametrized ADTs:
--
--     data Tree a = Node a | Branch (Tree a) (Tree a)
--     
--     foo :: Tree Int -> Int
--
--   Here the first parameter of foo would have something akin to:
--
--     TyConApp Tree [Int]
--
--   TyAlg is simply the ADT that lives in the environment. We don't actually
--   use the type environment at all during symbolic execution. However, the
--   type environment, as stated before, is crucial for reconstruction for when
--   we throw things at the SMT solver.
--
--   TyBottom is a default filler for when we don't have anything better to do.
data GenType n = TyVar n
               | TyRawInt | TyRawFloat | TyRawDouble | TyRawChar | TyRawString
               | TyFun (GenType n) (GenType n)
               | TyApp (GenType n) (GenType n)
               | TyConApp n [GenType n]
               | TyAlg n [GenDataCon n]
               | TyForAll n (GenType n)
               | TyBottom
               deriving (Show, Eq)

-- | Alternatives
--   [Name] refers to the parameters of the data constructor.
--
--   Matching in Case statemetns is done only on data constructors. This means,
--   for instance, that we are not able to perform direct matching on numbers,
--   which Core Haskell appears to be capable of. However, there are ways to
--   work around this if we are clever with a custom prelude.
data GenAlt n = Alt (GenDataCon n, [n]) deriving (Show, Eq)

-- | Path Condition
--   A single decision point in program execution.
--
--   CondAlt denotes structural matching as a result of Case/Alt statements.
--
--   CondExt denotes external specification derived from Assume/Assert.
data GenPathCond n = CondAlt (GenExpr n) (GenAlt n) Bool
                     | CondExt (GenExpr n) Bool
                     deriving (Show, Eq)
