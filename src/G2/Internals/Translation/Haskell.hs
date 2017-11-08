-- | Haskell Translation
module G2.Internals.Translation.Haskell
    ( CompileClosure
    , mkCompileClosure
    , hskToG2
    , mkIOString
    , mkPrims
    , prim_list
    , rawDump
    ) where

import qualified G2.Internals.Language as G2

import CoreSyn
import DataCon
import GHC
import GHC.Paths
import HscMain
import HscTypes
import Literal
import Name
import Outputable
import TidyPgm
import TyCon
import TyCoRep
import Unique
import Var as V

mkIOString :: (Outputable a) => a -> IO String
mkIOString obj = runGhc (Just libdir) $ do
    dflags <- getSessionDynFlags
    return (showPpr dflags obj)

mkRawCore :: FilePath -> IO CoreModule
mkRawCore fp = runGhc (Just libdir) $ do
    _ <- setSessionDynFlags =<< getSessionDynFlags
    -- compileToCoreModule fp
    compileToCoreSimplified fp

rawDump :: FilePath -> IO ()
rawDump fp = do
  core <- mkRawCore fp
  str <- mkIOString core
  putStrLn str

hskToG2 :: FilePath -> FilePath -> IO (G2.Program, [G2.ProgramType])
hskToG2 proj src = do
    (sums_gutss, _, _) <- mkCompileClosure proj src
    let binds = concatMap (\(_, _, b) -> map mkBinds b) sums_gutss
    let tycons = concatMap (\(_, t, _) -> map mkTyCon t) sums_gutss
    return (binds, tycons)

type CompileClosure = ([(ModSummary, [TyCon], [CoreBind])], DynFlags, HscEnv)

mkCompileClosure :: FilePath -> FilePath -> IO CompileClosure
mkCompileClosure proj src = do
    (mod_graph, mod_gutss, dflags, env) <- runGhc (Just libdir) $ do
      beta_flags <- getSessionDynFlags
      let dflags = beta_flags { importPaths = [proj] }
      _ <- setSessionDynFlags dflags
      env <- getSession
      target <- guessTarget src Nothing
      _ <- setTargets [target]
      _ <- load LoadAllTargets
      -- Now that things are loaded, make the compilation closure.
      mod_graph <- getModuleGraph
      pmods <- mapM parseModule mod_graph
      tmods <- mapM typecheckModule pmods
      dmods <- mapM desugarModule tmods
      let mod_gutss = map coreModule dmods
      return (mod_graph, mod_gutss, dflags, env)

    -- Perform simplification and tidying, which is necessary for getting the
    -- typeclass selector functions.
    smpl_gutss <- mapM (hscSimplify env) mod_gutss
    tidy_pgms <- mapM (tidyProgram env) smpl_gutss
    let cg_gutss = map fst tidy_pgms
    let tcss_pgms = map (\c -> (cg_tycons c, cg_binds c)) cg_gutss
    let (tcss, bindss) = unzip tcss_pgms
    return (zip3 mod_graph tcss bindss, dflags, env)
    -- return (zip3 mod_graph (map mg_tcs mod_gutss) (map mg_binds mod_gutss), dflags, env)

mkBinds :: CoreBind -> [(G2.Id, G2.Expr)]
mkBinds (NonRec var expr) = [(mkId var, mkExpr expr)]
mkBinds (Rec ves) = map (\(v, e) -> (mkId v, mkExpr e)) ves

mkExpr :: CoreExpr -> G2.Expr
mkExpr (Var var) = filterPrimOp (mkId var)
mkExpr (Lit lit) = G2.Lit (mkLit lit)
mkExpr (App fxpr axpr) = G2.App (mkExpr fxpr) (mkExpr axpr)
mkExpr (Lam var expr) = G2.Lam (mkId var) (mkExpr expr)
mkExpr (Let bnd expr) = G2.Let (mkBind bnd) (mkExpr expr)
mkExpr (Case mxpr var _ alts) = G2.Case (mkExpr mxpr) (mkId var) (mkAlts alts)
mkExpr (Cast expr _) = mkExpr expr
mkExpr (Tick _ expr) = mkExpr expr
mkExpr (Type ty) = G2.Type (mkType ty)
mkExpr (Coercion _) = error "mkExpr: Coercion"

mkId :: Id -> G2.Id
mkId vid = G2.Id ((mkName . V.varName) vid) ((mkType . varType) vid)

filterPrimOp :: G2.Id -> G2.Expr
filterPrimOp (G2.Id name ty) = expr
  where
    G2.Name occ mb_mdl _ = name
    ghc_tys = "GHC.Types"
    expr = case (mb_mdl == G2.Module ghc_tys, occ) of
                (True, ">=") -> G2.Prim G2.Ge G2.TyBottom
                (True, ">") -> G2.Prim G2.Gt G2.TyBottom
                (True, "==") -> G2.Prim G2.Eq G2.TyBottom
                (True, "<=") -> G2.Prim G2.Le G2.TyBottom
                (True, "<") -> G2.Prim G2.Lt G2.TyBottom
                (True, "&&") -> G2.Prim G2.And G2.TyBottom
                (True, "||") -> G2.Prim G2.Or G2.TyBottom
                (True, "not") -> G2.Prim G2.Not G2.TyBottom
                (True, "+") -> G2.Prim G2.Plus G2.TyBottom
                (True, "-") -> G2.Prim G2.Minus G2.TyBottom
                (True, "*") -> G2.Prim G2.Mult G2.TyBottom
                (True, "/") -> G2.Prim G2.Div G2.TyBottom
                _ -> G2.Var (G2.Id name ty)

mkName :: Name -> G2.Name
mkName name = G2.Name occ mdl unq
  where
    occ = (occNameString . nameOccName) name
    unq = (getKey . nameUnique) name
    mdl = case nameModule_maybe name of
              Nothing -> G2.None
              Just md -> G2.Module ((moduleNameString . moduleName) md)

mkLit :: Literal -> G2.Lit
mkLit (MachChar chr) = G2.LitChar chr
mkLit (MachStr bstr) = G2.LitString (show bstr)
mkLit (MachInt i) = G2.LitInt (fromInteger i)
mkLit (MachInt64 i) = G2.LitInt (fromInteger i)
mkLit (MachWord i) = G2.LitInt (fromInteger i)
mkLit (MachWord64 i) = G2.LitInt (fromInteger i)
mkLit (MachFloat rat) = G2.LitFloat rat
mkLit (MachDouble rat) = G2.LitDouble rat
mkLit (LitInteger i _) = G2.LitInt (fromInteger i)
mkLit (MachNullAddr) = error "mkLit: MachNullAddr"
mkLit (MachLabel _ _ _ ) = error "mkLit: MachLabel"

mkBind :: CoreBind -> [(G2.Id, G2.Expr)]
mkBind (NonRec var expr) = [(mkId var, mkExpr expr)]
mkBind (Rec ves) = map (\(v, e) -> (mkId v, mkExpr e)) ves

mkAlts :: [CoreAlt] -> [G2.Alt]
mkAlts alts = map mkAlt alts

mkAlt :: CoreAlt -> G2.Alt
mkAlt (acon, prms, expr) = G2.Alt (mkAltMatch acon prms) (mkExpr expr)

mkAltMatch :: AltCon -> [Var] -> G2.AltMatch
mkAltMatch (DataAlt dcon) params = G2.DataAlt (mkData dcon) (map mkId params)
mkAltMatch (LitAlt lit) _ = G2.LitAlt (mkLit lit)
mkAltMatch (DEFAULT) _ = G2.Default

mkType :: Type -> G2.Type
mkType (TyVarTy v) = G2.TyVar $ mkId v-- (mkName (V.varName v)) (mkType (varType v))
mkType (AppTy t1 t2) = G2.TyApp (mkType t1) (mkType t2)
mkType (ForAllTy (Anon t) ty) = G2.TyFun (mkType t) (mkType ty)
mkType (ForAllTy b ty) = G2.TyForAll (mkTyBinder b) (mkType ty)
mkType (LitTy _) = error "mkType: LitTy"
mkType (CastTy _ _) = error "mkType: CastTy"
mkType (CoercionTy _) = error "mkType: Coercion"
mkType (TyConApp tc ts) = if not (isFunTyCon tc)
    then G2.TyConApp (mkTyConName tc) (map mkType ts)
    else case ts of
        (t1:t2:[]) -> G2.TyFun (mkType t1) (mkType t2)
        _ -> error "mkType: non-arity 2 FunTyCon from GHC"

mkTyCon :: TyCon -> G2.ProgramType
mkTyCon t = (mkName . tyConName $ t, [], map mkData dc)
  where 
    dc = if isDataTyCon t then data_cons . algTyConRhs $ t else []

mkTyConName :: TyCon -> G2.Name
mkTyConName = mkName . tyConName

mkData :: DataCon -> G2.DataCon
mkData datacon = filterPrimCon (G2.DataCon name ty tys)
  where
    name = mkDataName datacon
    ty   = (mkType . dataConRepType) datacon
    tys  = map mkType (dataConOrigArgTys datacon)

filterPrimCon :: G2.DataCon -> G2.DataCon
filterPrimCon (G2.PrimCon lcon) = G2.PrimCon lcon
filterPrimCon (G2.DataCon name ty tys) = dcon
  where
    G2.Name occ mb_mdl _ = name
    ghc_tys = "GHC.Types"
    dcon = case (mb_mdl == G2.Module ghc_tys, occ) of
               (True, "I#") -> G2.PrimCon G2.I
               (True, "D#") -> G2.PrimCon G2.D
               (True, "F#") -> G2.PrimCon G2.F
               (True, "C#") -> G2.PrimCon G2.C
               _ -> G2.DataCon name ty tys

mkDataName :: DataCon -> G2.Name
mkDataName datacon = (mkName . dataConName) datacon

mkTyBinder :: TyBinder -> G2.TyBinder
mkTyBinder (Anon t) = G2.AnonTyBndr (mkType t)
mkTyBinder (Named v _) = G2.NamedTyBndr (mkId v)

prim_list :: [String]
prim_list = [">=", ">", "==", "/=", "<=", "<",
             "&&", "||", "not",
             "+", "-", "*", "/", "negate", "error" ]

mkPrims :: FilePath -> IO [(G2.Name, G2.Type)]
mkPrims prims = runGhc (Just libdir) $ do
    _ <- setSessionDynFlags =<< getSessionDynFlags
    core <- compileToCoreSimplified prims
    let vars = map fst $ concatMap mkBinds (cm_binds core)
    return $ map (\v -> (G2.idName v, G2.typeOf v)) vars

