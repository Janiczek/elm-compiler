{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Optimize.Expression
  ( optimize
  , destructArgs
  , optimizePotentialTailCall
  )
  where


import Prelude hiding (cycle)
import Control.Monad (foldM)
import Data.Map ((!))
import qualified Data.Map as Map
import qualified Data.Name as Name
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified AST.Optimized as Opt
import qualified Data.Index as Index
import qualified Elm.ModuleName as ModuleName
import qualified Optimize.Case as Case
import qualified Optimize.Names as Names
import qualified Reporting.Annotation as A



-- OPTIMIZE


type Cycle =
  Set.Set Name.Name


optimize :: Map.Map Name.Name Can.Annotation -> Cycle -> Can.Expr -> Names.Tracker Opt.Expr
optimize ann cycle (A.At _ expression) =
  case expression of
    Can.VarLocal name ->
      pure (Opt.VarLocal name)

    Can.VarTopLevel home name ->
      if Set.member name cycle then
        pure (Opt.VarCycle home name)
      else
        Names.registerGlobal home name

    Can.VarForeign home name _ ->
      Names.registerGlobal home name

    Can.VarCtor adtName home ctorName _ _ ->
      Names.registerCtor adtName home ctorName

    Can.VarOperator _ home name _ ->
      Names.registerGlobal home name

    Can.Intrinsic name ->
      let (Can.Forall _ tipe) = ann ! name
       in Names.registerIntrinsic tipe name

    Can.Chr chr ->
      pure (Opt.Chr chr)

    Can.Str str ->
      pure (Opt.Str str)

    Can.Int int ->
      pure (Opt.Int int)

    Can.Float float ->
      pure (Opt.Float float)

    Can.List entries ->
      Opt.List <$> traverse (optimize ann cycle) entries

    Can.Negate expr ->
      do  func <- Names.registerGlobal ModuleName.basics Name.negate
          arg <- optimize ann cycle expr
          pure $ Opt.Call func [arg]

    Can.Binop _ home name _ left right ->
      do  optFunc <- Names.registerGlobal home name
          optLeft <- optimize ann cycle left
          optRight <- optimize ann cycle right
          return (Opt.Call optFunc [optLeft, optRight])

    Can.Lambda args body ->
      do  (argNames, destructors) <- destructArgs args
          obody <- optimize ann cycle body
          pure $ Opt.Function argNames (foldr Opt.Destruct obody destructors)

    Can.Call func args ->
      Opt.Call
        <$> optimize ann cycle func
        <*> traverse (optimize ann cycle) args

    Can.If branches finally ->
      let
        optimizeBranch (condition, branch) =
          (,)
            <$> optimize ann cycle condition
            <*> optimize ann cycle branch
      in
      Opt.If
        <$> traverse optimizeBranch branches
        <*> optimize ann cycle finally

    Can.Let def body ->
      optimizeDef ann cycle def =<< optimize ann cycle body

    Can.LetRec defs body ->
      case defs of
        [def] ->
          Opt.Let
            <$> optimizePotentialTailCallDef ann cycle def
            <*> optimize ann cycle body

        _ ->
          do  obody <- optimize ann cycle body
              foldM (\bod def -> optimizeDef ann cycle def bod) obody defs

    Can.LetDestruct pattern expr body ->
      do  (name, destructs) <- destruct pattern
          oexpr <- optimize ann cycle expr
          obody <- optimize ann cycle body
          pure $
            Opt.Let (Opt.Def name oexpr) (foldr Opt.Destruct obody destructs)

    Can.Case expr branches ->
      let
        optimizeBranch root (Can.CaseBranch pattern branch) =
          do  destructors <- destructCase root pattern
              obranch <- optimize ann cycle branch
              pure (pattern, foldr Opt.Destruct obranch destructors)
      in
      do  temp <- Names.generate
          oexpr <- optimize ann cycle expr
          case oexpr of
            Opt.VarLocal root ->
              Case.optimize temp root <$> traverse (optimizeBranch root) branches

            _ ->
              do  obranches <- traverse (optimizeBranch temp) branches
                  return $ Opt.Let (Opt.Def temp oexpr) (Case.optimize temp temp obranches)

    Can.Accessor field ->
      Names.registerField field (Opt.Accessor field)

    Can.Access record (A.At _ field) ->
      do  optRecord <- optimize ann cycle record
          Names.registerField field (Opt.Access optRecord field)

    Can.Update _ record updates ->
      Names.registerFieldDict updates Opt.Update
        <*> optimize ann cycle record
        <*> traverse (optimizeUpdate ann cycle) updates

    Can.Record fields ->
      Names.registerFieldDict fields Opt.Record
        <*> traverse (optimize ann cycle) fields

    Can.Unit ->
      pure Opt.Unit

    Can.Tuple a b maybeC ->
      Opt.Tuple
        <$> optimize ann cycle a
        <*> optimize ann cycle b
        <*> traverse (optimize ann cycle) maybeC



-- UPDATE


optimizeUpdate :: Map.Map Name.Name Can.Annotation -> Cycle -> Can.FieldUpdate -> Names.Tracker Opt.Expr
optimizeUpdate ann cycle (Can.FieldUpdate _ expr) =
  optimize ann cycle expr



-- DEFINITION


optimizeDef :: Map.Map Name.Name Can.Annotation -> Cycle -> Can.Def -> Opt.Expr -> Names.Tracker Opt.Expr
optimizeDef ann cycle def body =
  case def of
    Can.Def (A.At _ name) args expr ->
      optimizeDefHelp ann cycle name args expr body

    Can.TypedDef (A.At _ name) _ typedArgs expr _ ->
      optimizeDefHelp ann cycle name (map fst typedArgs) expr body


optimizeDefHelp :: Map.Map Name.Name Can.Annotation -> Cycle -> Name.Name -> [Can.Pattern] -> Can.Expr -> Opt.Expr -> Names.Tracker Opt.Expr
optimizeDefHelp ann cycle name args expr body =
  do  oexpr <- optimize ann cycle expr
      case args of
        [] ->
          pure $ Opt.Let (Opt.Def name oexpr) body

        _ ->
          do  (argNames, destructors) <- destructArgs args
              let ofunc = Opt.Function argNames (foldr Opt.Destruct oexpr destructors)
              pure $ Opt.Let (Opt.Def name ofunc) body



-- DESTRUCTURING


destructArgs :: [Can.Pattern] -> Names.Tracker ([Name.Name], [Opt.Destructor])
destructArgs args =
  do  (argNames, destructorLists) <- unzip <$> traverse destruct args
      return (argNames, concat destructorLists)


destructCase :: Name.Name -> Can.Pattern -> Names.Tracker [Opt.Destructor]
destructCase rootName pattern =
  reverse <$> destructHelp (Opt.Root rootName) pattern []


destruct :: Can.Pattern -> Names.Tracker (Name.Name, [Opt.Destructor])
destruct pattern@(A.At _ ptrn) =
  case ptrn of
    Can.PVar name ->
      pure (name, [])

    Can.PAlias subPattern name ->
      do  revDs <- destructHelp (Opt.Root name) subPattern []
          pure (name, reverse revDs)

    _ ->
      do  name <- Names.generate
          revDs <- destructHelp (Opt.Root name) pattern []
          pure (name, reverse revDs)


destructHelp :: Opt.Path -> Can.Pattern -> [Opt.Destructor] -> Names.Tracker [Opt.Destructor]
destructHelp path (A.At region pattern) revDs =
  case pattern of
    Can.PAnything ->
      pure revDs

    Can.PVar name ->
      pure (Opt.Destructor name path : revDs)

    Can.PRecord fields ->
      let
        toDestruct name =
          Opt.Destructor name (Opt.Field name path)
      in
      Names.registerFieldList fields (map toDestruct fields ++ revDs)

    Can.PAlias subPattern name ->
      destructHelp (Opt.Root name) subPattern $
        Opt.Destructor name path : revDs

    Can.PUnit ->
      pure revDs

    Can.PTuple a b Nothing ->
      destructTwo path a b revDs

    Can.PTuple a b (Just c) ->
      -- TODO Elm->Bend: somehow do all three at the same time?
      case path of
        Opt.Root _ ->
          destructHelp (Opt.GetTripleEl2 path) c =<<
            destructHelp (Opt.GetTripleEl1 path) b =<<
              destructHelp (Opt.GetTripleEl0 path) a revDs

        _ ->
          do  name <- Names.generate
              let newRoot = Opt.Root name
              destructHelp (Opt.GetTripleEl2 newRoot) c =<<
                destructHelp (Opt.GetTripleEl1 newRoot) b =<<
                  destructHelp (Opt.GetTripleEl0 newRoot) a (Opt.Destructor name path : revDs)

    Can.PList [] ->
      pure revDs

    Can.PList (hd:tl) ->
      destructTwo path hd (A.At region (Can.PList tl)) revDs

    Can.PCons hd tl ->
      destructTwo path hd tl revDs

    Can.PChr _ ->
      pure revDs

    Can.PStr _ ->
      pure revDs

    Can.PInt _ ->
      pure revDs

    Can.PBool _ _ ->
      pure revDs

    Can.PCtor _ _ (Can.Union _ _ _) _ _ args ->
      case args of
        [Can.PatternCtorArg _ _ arg] ->
          destructHelp (Opt.CtorIndex Index.first path) arg revDs

        _ ->
          case path of
            Opt.Root _ ->
              foldM (destructCtorArg path) revDs args

            _ ->
              do  name <- Names.generate
                  foldM (destructCtorArg (Opt.Root name)) (Opt.Destructor name path : revDs) args


destructTwo :: Opt.Path -> Can.Pattern -> Can.Pattern -> [Opt.Destructor] -> Names.Tracker [Opt.Destructor]
destructTwo path a b revDs =
  case path of
    Opt.Root _ ->
      destructHelp (Opt.GetTupleEl1 path) b =<<
        destructHelp (Opt.GetTupleEl0 path) a revDs

    _ ->
      do  name <- Names.generate
          let newRoot = Opt.Root name
          destructHelp (Opt.GetTupleEl1 newRoot) b =<<
            destructHelp (Opt.GetTupleEl0 newRoot) a (Opt.Destructor name path : revDs)


destructCtorArg :: Opt.Path -> [Opt.Destructor] -> Can.PatternCtorArg -> Names.Tracker [Opt.Destructor]
destructCtorArg path revDs (Can.PatternCtorArg index _ arg) =
  destructHelp (Opt.CtorIndex index path) arg revDs



-- TAIL CALL


optimizePotentialTailCallDef :: Map.Map Name.Name Can.Annotation -> Cycle -> Can.Def -> Names.Tracker Opt.Def
optimizePotentialTailCallDef ann cycle def =
  case def of
    Can.Def (A.At _ name) args expr ->
      optimizePotentialTailCall ann cycle name args expr

    Can.TypedDef (A.At _ name) _ typedArgs expr _ ->
      optimizePotentialTailCall ann cycle name (map fst typedArgs) expr


optimizePotentialTailCall :: Map.Map Name.Name Can.Annotation -> Cycle -> Name.Name -> [Can.Pattern] -> Can.Expr -> Names.Tracker Opt.Def
optimizePotentialTailCall ann cycle name args expr =
  do  (argNames, destructors) <- destructArgs args
      toTailDef name argNames destructors <$>
        optimizeTail ann cycle name argNames expr


optimizeTail :: Map.Map Name.Name Can.Annotation -> Cycle -> Name.Name -> [Name.Name] -> Can.Expr -> Names.Tracker Opt.Expr
optimizeTail ann cycle rootName argNames locExpr@(A.At _ expression) =
  case expression of
    Can.Call func args ->
      do  oargs <- traverse (optimize ann cycle) args

          let (isMatchingName, currentModule) =
                case A.toValue func of
                  Can.VarLocal      name -> (rootName == name, Nothing)
                  Can.VarTopLevel m name -> (rootName == name, Just m)
                  _                      -> (False, Nothing)

          if isMatchingName
            then
              case Index.indexedZipWith (\_ a b -> (a,b)) argNames oargs of
                Index.LengthMatch pairs ->
                  pure $ Opt.TailCall currentModule rootName pairs

                Index.LengthMismatch _ _ ->
                  do  ofunc <- optimize ann cycle func
                      pure $ Opt.Call ofunc oargs
            else
              do  ofunc <- optimize ann cycle func
                  pure $ Opt.Call ofunc oargs

    Can.If branches finally ->
      let
        optimizeBranch (condition, branch) =
          (,)
            <$> optimize ann cycle condition
            <*> optimizeTail ann cycle rootName argNames branch
      in
      Opt.If
        <$> traverse optimizeBranch branches
        <*> optimizeTail ann cycle rootName argNames finally

    Can.Let def body ->
      optimizeDef ann cycle def =<< optimizeTail ann cycle rootName argNames body

    Can.LetRec defs body ->
      case defs of
        [def] ->
          Opt.Let
            <$> optimizePotentialTailCallDef ann cycle def
            <*> optimizeTail ann cycle rootName argNames body

        _ ->
          do  obody <- optimizeTail ann cycle rootName argNames body
              foldM (\bod def -> optimizeDef ann cycle def bod) obody defs

    Can.LetDestruct pattern expr body ->
      do  (dname, destructors) <- destruct pattern
          oexpr <- optimize ann cycle expr
          obody <- optimizeTail ann cycle rootName argNames body
          pure $
            Opt.Let (Opt.Def dname oexpr) (foldr Opt.Destruct obody destructors)

    Can.Case expr branches ->
      let
        optimizeBranch root (Can.CaseBranch pattern branch) =
          do  destructors <- destructCase root pattern
              obranch <- optimizeTail ann cycle rootName argNames branch
              pure (pattern, foldr Opt.Destruct obranch destructors)
      in
      do  temp <- Names.generate
          oexpr <- optimize ann cycle expr
          case oexpr of
            Opt.VarLocal root ->
              Case.optimize temp root <$> traverse (optimizeBranch root) branches

            _ ->
              do  obranches <- traverse (optimizeBranch temp) branches
                  return $ Opt.Let (Opt.Def temp oexpr) (Case.optimize temp temp obranches)

    _ ->
      optimize ann cycle locExpr



-- DETECT TAIL CALLS


toTailDef :: Name.Name -> [Name.Name] -> [Opt.Destructor] -> Opt.Expr -> Opt.Def
toTailDef name argNames destructors body =
  if hasTailCall body then
    Opt.TailDef name argNames (foldr Opt.Destruct body destructors)
  else
    Opt.Def name (Opt.Function argNames (foldr Opt.Destruct body destructors))


hasTailCall :: Opt.Expr -> Bool
hasTailCall expression =
  case expression of
    Opt.TailCall _ _ _ ->
      True

    Opt.If branches finally ->
      hasTailCall finally || any (hasTailCall . snd) branches

    Opt.Let _ body ->
      hasTailCall body

    Opt.Destruct _ body ->
      hasTailCall body

    Opt.Case _ _ decider jumps ->
      deciderHasTailCall decider || any (hasTailCall . snd) jumps

    _ ->
      False


deciderHasTailCall :: Opt.Decider Opt.Choice -> Bool
deciderHasTailCall decider =
  case decider of
    Opt.Leaf choice ->
      case choice of
        Opt.Inline expr ->
          hasTailCall expr

        Opt.Jump _ ->
          False

    Opt.Chain _ success failure ->
      deciderHasTailCall success || deciderHasTailCall failure

    Opt.FanOut _ tests fallback ->
      deciderHasTailCall fallback || any (deciderHasTailCall . snd) tests
