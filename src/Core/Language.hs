module G2.Core.Language where

import qualified Data.Map as M

type State = (TEnv, EEnv, Expr, PC)

type Name = String

type TEnv = M.Map Name Type

type EEnv = M.Map Name Expr

data Expr = Var Name Type
          | Const Const Type
          | Lam Name Expr Type
          | App Expr Expr
          | DCon DataCon Type
          | Case Expr [(Alt, Expr)] Type
          | BAD
          | UNR
          deriving (Show, Eq)

data Const = CInt Int
           | CReal Rational
           | CChar Char
           deriving (Show, Eq)

type DataCon = (Name, Int, Type, [Type])

data Type = TyVar Name
          | TyInt | TyReal | TyChar | TyBool
          | TyFun Type Type
          | TyApp Type Type
          | TyConApp Name [Type]
          | TyAlg Name [DataCon]
          | TyBottom
          deriving (Show, Eq)

type Alt = (DataCon, [Name])

type PC = [(Expr, Alt)]

