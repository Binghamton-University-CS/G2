{-# LANGUAGE OverloadedStrings #-}
module InputOutputTest where

import Test.Tasty
import Test.Tasty.HUnit

import Control.Exception
import qualified Data.Text as T

import G2.Config
import G2.Interface
import G2.Language
import G2.Liquid.Interface
import G2.Translation

import Reqs

checkInputOutput :: FilePath -> FilePath -> String -> String -> Int -> Int -> [Reqs String] ->  IO TestTree
checkInputOutput proj src md entry stps i req = checkInputOutputWithConfig proj src md entry i req (mkConfigDef {steps = stps})

checkInputOutputWithConfig :: FilePath -> FilePath -> String -> String -> Int -> [Reqs String] -> Config -> IO TestTree
checkInputOutputWithConfig proj src md entry i req config = do
    r <- checkInputOutput' proj src md entry i req config

    let (b, e) = case r of
            Left e' -> (False, "\n" ++ show e')
            Right (b', s') -> (b', concatMap (\(_, inp, out, _) -> "\n" ++ show inp ++ "\n" ++ show out) s')

    return . testCase src $ assertBool ("Input/Output for file " ++ show src ++ " failed on function " ++ entry ++ "." ++ e) b 

checkInputOutput' :: FilePath 
                  -> FilePath 
                  -> String 
                  -> String 
                  -> Int 
                  -> [Reqs String] 
                  -> Config 
                  -> IO (Either SomeException (Bool, [(State (), [Expr], Expr, Maybe FuncCall)]))
checkInputOutput' proj src md entry i req config = try (checkInputOutput'' proj src md entry i req config)

checkInputOutput'' :: FilePath 
                   -> FilePath 
                   -> String 
                   -> String 
                   -> Int 
                   -> [Reqs String] 
                   -> Config 
                   -> IO (Bool, [(State (), [Expr], Expr, Maybe FuncCall)])
checkInputOutput'' proj src md entry i req config = do
    (mb_modname, binds, tycons, cls, _, ex) <- translateLoaded proj src [] False config

    let (init_state, _) = initState binds tycons cls Nothing Nothing Nothing False (T.pack entry) mb_modname ex config
    
    r <- runG2WithConfig init_state config

    let chAll = checkExprAll req
    mr <- validateStates proj src md entry chAll [] r
    let io = map (\(_, i', o, _) -> i' ++ [o]) r

    let chEx = checkExprInOutCount io i req
    
    return $ (mr && chEx, r)

------------

checkInputOutputLH :: FilePath -> FilePath -> String -> String -> Int -> Int -> [Reqs String] ->  IO TestTree
checkInputOutputLH proj src md entry stps i req = checkInputOutputLHWithConfig proj src md entry i req (mkConfigDef {steps = stps})

checkInputOutputLHWithConfig :: FilePath -> FilePath -> String -> String -> Int -> [Reqs String] -> Config -> IO TestTree
checkInputOutputLHWithConfig proj src md entry i req config = do
    r <- checkInputOutputLH' proj src md entry i req config

    let b = case r of
            Left _ -> False
            Right b' -> b'

    return . testCase src $ assertBool ("Input/Output for file " ++ show src ++ " failed on function " ++ entry ++ ".") b

checkInputOutputLH' :: FilePath -> FilePath -> String -> String -> Int -> [Reqs String] -> Config -> IO (Either SomeException Bool)
checkInputOutputLH' proj src md entry i req config = try (checkInputOutputLH'' proj src md entry i req config)

checkInputOutputLH'' :: FilePath -> FilePath -> String -> String -> Int -> [Reqs String] -> Config -> IO Bool
checkInputOutputLH'' proj src md entry i req config = do
    (r, _) <- findCounterExamples proj src (T.pack entry) [] [] config

    let chAll = checkExprAll req

    mr <- validateStates proj src md entry chAll [] r
    let io = map (\(_, i', o, _) -> i' ++ [o]) r

    let chEx = checkExprInOutCount io i req
    return $ mr && chEx

------------

-- | Checks conditions on given expressions
checkExprAll :: [Reqs String] -> [String]
checkExprAll reqList = [f | RForAll f <- reqList]

checkExprExists :: [Reqs String] -> [String]
checkExprExists reqList = [f | RExists f <- reqList]

checkExprInOutCount :: [[Expr]] -> Int -> [Reqs c] -> Bool
checkExprInOutCount exprs i reqList =
    let
        checkAtLeast = and . map ((>=) (length exprs)) $ [x | AtLeast x <- reqList]
        checkAtMost = and . map ((<=) (length exprs)) $ [x | AtMost x <- reqList]
        checkExactly = and . map ((==) (length exprs)) $ [x | Exactly x <- reqList]

        checkArgCount = and . map ((==) i . length) $ exprs
    in
    checkAtLeast && checkAtMost && checkExactly && checkArgCount
