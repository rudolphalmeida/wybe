--  File     : Types.hs
--  Author   : Peter Schachte
--  Origin   : Sun Jan 15 16:00:18 2012
--  Purpose  : Type checker/inferencer for Wybe
--  Copyright: � 2012 Peter Schachte.  All rights reserved.

-- |Support for type checking/inference.
module Types (typeCheckModSCC) where

import AST
import Data.Map as Map
import Data.Set as Set
import Data.List as List
import Control.Monad.State
import Data.Maybe
import Data.Graph

import Debug.Trace

-- |The reason a variable is given a certain type
data TypeReason = ReasonParam Int     -- Specified by param type/flow
                | ReasonArg OptPos ProcSpec Int
                                      -- Specified by call type/flow
                deriving (Eq)

instance Show TypeReason where
    show (ReasonParam num) = "Parameter " ++ show num
    show (ReasonArg pos pspec num) =
        makeMessage pos $
        "Argument " ++ show num ++ " of call to " ++ show pspec

data Typing = ValidTyping (Map VarName (TypeSpec,TypeReason))
            | InvalidTyping2 TypeReason TypeReason   -- conflicting var uses
            | InvalidTyping1 TypeReason              -- conflict w/callee
            deriving (Show,Eq)

initTyping :: Typing
initTyping = ValidTyping Map.empty


validTyping :: Typing -> Bool
validTyping (ValidTyping _) = True
validTyping _ = False


addOneType :: TypeReason -> PrimVarName -> TypeSpec -> Typing -> Typing
addOneType reason (PrimVarName name _) typ valid@(ValidTyping types) =
    case Map.lookup name types of
        Nothing -> ValidTyping $ Map.insert name (typ,reason) types
        Just (oldTyp,oldReason) ->
            if typ == oldTyp 
            then valid
            else if typ `properSubtypeOf` oldTyp
                 then ValidTyping $ Map.insert name (typ,reason) types
                 else InvalidTyping2 oldReason reason
addOneType _ _ _ invalid = invalid


-- |Returns the first argument restricted to the variables appearing 
--  in the second.
projectTyping :: Typing -> Typing -> Typing
projectTyping (ValidTyping typing) (ValidTyping interest) =
    ValidTyping $
    Map.filterWithKey (\k _ -> isJust $ Map.lookup k interest) typing
projectTyping typing _ = typing


-- Simple subtype relation for now; every type is a subtype of the 
-- unspecified type.
properSubtypeOf :: TypeSpec -> TypeSpec -> Bool
properSubtypeOf _ Unspecified = True
properSubtypeOf _ _ = False


subtypeOf :: TypeSpec -> TypeSpec -> Bool
subtypeOf sub super = sub == super || sub `properSubtypeOf` super


-- |Type check a strongly connected component in the module dependency graph.
--  This code assumes that all lower sccs have already been checked.
typeCheckModSCC :: [ModSpec] -> Compiler ()
typeCheckModSCC [modspec] = do  -- immediate fixpoint when no mutual dependency
    typeCheckMod [modspec] modspec
    return ()
typeCheckModSCC scc = do        -- must find fixpoint
    changed <- mapM (typeCheckMod scc) scc
    when (or changed) $ typeCheckModSCC scc


-- |Type check a single module named in the second argument; the 
--  first argument is a list of all the modules in this module 
-- dependency SCC.
-- XXX must check submodules, too.
typeCheckMod :: [ModSpec] -> ModSpec -> Compiler Bool
typeCheckMod scc thisMod = do
    -- liftIO $ putStrLn $ "Type checking module " ++ showModSpec thisMod
    reenterModule thisMod
    procs <- getModule (Map.toList . modProcs . fromJust . modImplementation)
    let ordered =
            stronglyConnComp
            [(name,name,nub $ localCalledProcs thisMod $ List.map content
                      $ concat $ concat $ List.map procBody procs) 
             | (name,procs) <- procs]
    changed <- mapM (typecheckProcSCC thisMod scc) ordered
    finishModule
    return $ or changed


-- |The list of procs in the current module called in the specified 
--  list of prims.  
localCalledProcs :: ModSpec -> [Prim] -> [Ident]
localCalledProcs _ [] = []
localCalledProcs thisMod (PrimCall [] name _ _:rest) =
    name:localCalledProcs thisMod rest
localCalledProcs thisMod (PrimCall m name _ _:rest)
  | m == thisMod = name:localCalledProcs thisMod rest
localCalledProcs thisMod (_:rest) = localCalledProcs thisMod rest


-- |Type check one strongly connected component in the local call graph
--  of a module.  The call graph contains only procs in the one module,
--  because this is being done for type inference, and imported procs
--  must have had their types declared.  Returns True if the inferred 
--  types are more specific than the old ones and some proc(s) in the 
--  SCC depend on procs in the list of mods.  In this case, we will 
--  have to rerun the typecheck after typechecking the other modules 
--  on that list. 
typecheckProcSCC :: ModSpec -> [ModSpec] -> SCC ProcName ->
                    Compiler Bool
typecheckProcSCC m mods (AcyclicSCC name) = do
    -- A single pass is always enough for non-cyclic SCCs
    -- liftIO $ putStrLn $ "Type checking non-recursive proc " ++ name
    (_,allAgain) <- typecheckProcDefs m mods name
    return allAgain
typecheckProcSCC m mods (CyclicSCC list) = do
    -- liftIO $ putStrLn $ "Type checking recursive procs " ++ 
    --   intercalate ", " list
    (modAgain,allAgain) <-
        foldM (\(modAgain,allAgain) name -> do
                    (modAgain',allAgain') <- typecheckProcDefs m mods name
                    return (modAgain || modAgain', allAgain || allAgain'))
        (False, False) list
    if modAgain
      then typecheckProcSCC m mods $ CyclicSCC list
      else return allAgain


-- |Type check a list of procedure definitions and update the 
--  definitions stored in the Compiler monad.  Returns a pair of 
--  Bools, the first saying whether any defnition has been udpated, 
--  and the second saying whether any public defnition has been 
--  updated.
typecheckProcDefs :: ModSpec -> [ModSpec] -> ProcName -> Compiler (Bool,Bool)
typecheckProcDefs m mods name = do
    
    defs <- getModule (Map.findWithDefault (error "missing proc definition")
                       name . modProcs . fromJust . modImplementation)
    (revdefs,modAgain,allAgain) <- 
        foldM (\(ds,modAgain,allAgain) def -> do
                    (d,mA,aA) <- typecheckProcDef m mods def
                    return (d:ds,modAgain || mA,allAgain || aA))
        ([],False,False) defs
    when modAgain $
      updateModImplementation
      (\imp -> imp { modProcs = Map.insert name (reverse revdefs) 
                                $ modProcs imp })
    return (modAgain,allAgain)
    

-- |Type check a single procedure definition.
typecheckProcDef :: ModSpec -> [ModSpec] -> ProcDef ->
                    Compiler (ProcDef,Bool,Bool)
typecheckProcDef m mods pd@(ProcDef name proto@(PrimProto pn params) 
                         def pos tmpCnt vis) 
  = do
    let typing = List.foldr addDeclaredType initTyping $ zip params [1..]
    if validTyping typing
      then do
        -- liftIO $ putStrLn $ "** Type checking " ++ name ++
        --   ": " ++ show typing
        (typing',def') <- typecheckBody m mods typing def
        -- liftIO $ putStrLn $ "*resulting types " ++ name ++
        --   ": " ++ show typing'
        let params' = updateParamTypes typing' params
        let pd' = ProcDef name (PrimProto pn params') def' pos tmpCnt vis
        let modAgain = pd' /= pd
        -- when modAgain
        --      (liftIO $ putStrLn $ "** check again " ++ name ++
        --              "\n-----------------OLD:" ++ showProcDef 4 pd ++
        --              "\n-----------------NEW:" ++ showProcDef 4 pd' ++ "\n")
        return (pd',modAgain,modAgain && vis == Public)
      else
        shouldnt $ "Inconsistent param typing for proc " ++ name


addDeclaredType :: (PrimParam,Int) -> Typing -> Typing
addDeclaredType (PrimParam name typ _ _,argNum) typs =
     addOneType (ReasonParam argNum) name typ typs


updateParamTypes :: Typing -> [PrimParam] -> [PrimParam]
updateParamTypes (ValidTyping dict) params =
    List.map (\p@(PrimParam name@(PrimVarName n _) typ fl afl) ->
               case Map.lookup n dict of
                   Nothing -> p
                   Just (newTyp,_) -> (PrimParam name newTyp fl afl)) params
updateParamTypes _ params = params


-- |Type check the body of a single proc definition by type checking 
--  each clause in turn using the declared parameter typing plus the 
--  typing of all parameters inferred from previous clauses.  We can 
--  stop once we've found a contradiction.
typecheckBody :: ModSpec -> [ModSpec] -> Typing -> [[Placed Prim]] -> 
                    Compiler (Typing,[[Placed Prim]])
typecheckBody m mods paramTypes body = do
    bodyTypes <- foldM (typecheckClause m mods) [(paramTypes,[])] body
    case bodyTypes of
      [] -> do
        -- liftIO $ putStrLn $ "   no valid type"
        message Error ("No valid type") Nothing
        return (paramTypes,body)
      [(typing,body')] -> do
        -- liftIO $ putStrLn $ "   final typing: " ++ show typing
        -- liftIO $ putStrLn $ "   final body: " ++ show body'
        when (projectTyping typing paramTypes /= typing)
                   (error "Typing not projected onto parameters!")
             
        return (projectTyping typing paramTypes, List.reverse body')
      _ -> do
        -- liftIO $ putStrLn $ "   ambiguous: " ++ show (length bodyTypes) ++
        --        " typings:\n" ++ show bodyTypes
        message Error ("Ambiguous types") Nothing
        return (paramTypes,body)


-- |Type check a single clause starting with each possible parameter 
--  typing. 
typecheckClause :: ModSpec -> [ModSpec] -> [(Typing, [[Placed Prim]])] -> 
                   [Placed Prim] -> Compiler [(Typing,[[Placed Prim]])]
typecheckClause m mods possibles prims = do
    possibles' <- mapM (typecheckPrims m mods prims) possibles
    return $ concat possibles'


-- |Type all prims in a clause starting with one possible parameter 
--  typing and producing all possible typings and the corresponding 
--  clause body.  The clause is returned in reverse.
typecheckPrims :: ModSpec -> [ModSpec] -> [Placed Prim] ->
                  (Typing, [[Placed Prim]]) ->
                  Compiler [(Typing,[[Placed Prim]])]
typecheckPrims m mods clause (types,clauses) = do
    clauseTypes <- foldM (typecheckPlacedPrim m mods) [(types,[])] clause
    return $ List.map (\(clTyping,cl) ->
                        (projectTyping clTyping types, reverse cl:clauses))
      clauseTypes

-- |Type check a single placed primitive operation given a list of 
--  possible starting typings and corresponding clauses up to this prim.
typecheckPlacedPrim :: ModSpec -> [ModSpec] -> [(Typing,[Placed Prim])] ->
                       Placed Prim -> Compiler [(Typing,[Placed Prim])]
typecheckPlacedPrim m mods possibilities pprim = do
    -- liftIO $ putStrLn $ "Type checking prim " ++ show pprim
    possposs <- mapM (typecheckPrim m mods (content pprim) (place pprim)) 
                possibilities
    -- liftIO $ putStrLn $ "Done checking prim " ++ show pprim
    return $ concat possposs
    

-- |Type check a single primitive operation, producing a list of 
--  possible typings and corresponding clauses.
typecheckPrim :: ModSpec -> [ModSpec] -> Prim -> OptPos ->
                 (Typing,[Placed Prim]) ->
                 Compiler [(Typing,[Placed Prim])]
typecheckPrim m mods prim pos (typing,body) = do
    possibilities <- typecheckSingle m mods prim pos typing
    return $ List.map (\(typing',prim') -> 
                        (typing',maybePlace prim' pos:body)) possibilities


-- |Type check one primitive operation, producing a list of 
--  possible typings and corresponding resolved primitives.
typecheckSingle :: ModSpec -> [ModSpec] -> Prim -> OptPos -> Typing ->
                 Compiler [(Typing,Prim)]
typecheckSingle m mods call@(PrimCall cm name id args) pos typing = do
    -- liftIO $ putStrLn $ "Type checking call " ++ show call
    -- liftIO $ putStrLn $ "   with types " ++ show typing
    procs <- case id of
        Nothing   -> callTargets cm name
        Just spec -> return [spec]
    -- liftIO $ putStrLn $ "   " ++ show (length procs) ++ " potential procs"
    if List.null procs 
    then do
      message Error ("Call to unknown " ++ name) pos
      return [(typing,PrimCall cm name id args)]
    else do
      pairsList <- mapM (\p -> do
                           params <- getParams p
                           if length params == length args
                           then do
                             -- liftIO $ putStrLn $ "   checking args " ++
                             --        show args ++ " against params " ++
                             --        show params
                             let (typing',revArgs) =
                                     List.foldr (typecheckArg pos p) 
                                     (typing,[]) $ zip3 [1..] params args
                             return [(typing',
                                      PrimCall cm name (Just p) revArgs)]
                           else
                               return [])
                   procs
      let pairs = concat pairsList
      let validPairs = List.filter (validTyping . fst) pairs
      -- liftIO $ putStrLn $ "   " ++ show (length validPairs) ++ " matching procs"
      if List.null validPairs 
      then do
        message Error ("Error in call:\n" ++ 
                       reportTypeErrors (List.map fst pairs)) pos
        return [(typing,PrimCall cm name id args)]
      else
          return validPairs
typecheckSingle _ _ (PrimForeign lang name id args) pos typing = do
    -- XXX must get type and flow from foreign calls
    return [(typing,PrimForeign lang name id args)]
typecheckSingle m mods (PrimGuard body val) pos typing = do
    checked <- foldM (typecheckPlacedPrim m mods) [(typing,[])] body
    return $ List.map (\(ty,body') -> (ty,PrimGuard (reverse body') val))
      checked
typecheckSingle _ _ PrimFail pos typing = return [(typing,PrimFail)]
typecheckSingle _ _ PrimNop pos typing = return [(typing,PrimNop)]


reportTypeErrors :: [Typing] -> String
reportTypeErrors reasons = intercalate "\n" $ List.map reportError reasons


reportError :: Typing -> String
reportError (InvalidTyping2 reason1 reason2) =
    "    " ++ show reason1 ++ " conflicts with\n     " ++ show reason2
reportError (InvalidTyping1 reason) =
    "    " ++ show reason ++ " conflicts with definition"
reportError nonerr = shouldnt $ "Reporting non-type error " ++ show nonerr


argType :: Typing -> PrimArg -> TypeSpec
argType (ValidTyping dict) (ArgVar (PrimVarName var _) typ _ _) = 
    maybe typ fst (Map.lookup var dict)
argType _ (ArgVar _ typ _ _) = typ
argType _ (ArgInt _ _)     = (TypeSpec ["wybe"] "int" [])
argType _ (ArgFloat _ _)   = (TypeSpec ["wybe"] "float" [])
argType _ (ArgString _ _)  = (TypeSpec ["wybe"] "string" [])
argType _ (ArgChar _ _)    = (TypeSpec ["wybe"] "char" [])


typecheckArg :: OptPos -> ProcSpec -> (Int,PrimParam,PrimArg) ->
                (Typing,[PrimArg]) -> (Typing,[PrimArg])
typecheckArg pos pspec (argNum,param,arg) (typing,args) =
    let actualFlow = argFlowDirection arg
        formalFlow = primParamFlow param
        reason = ReasonArg pos pspec argNum
    in  if not $ validTyping typing
        then (typing,args)
        else if formalFlow /= actualFlow
             then -- trace ("wrong flow: " ++ show arg ++ " against " ++ show param) 
                      (InvalidTyping1 reason,args)
             else -- trace ("OK flow: " ++ show arg ++ " against " ++ show param)
                  typecheckArg' arg (primParamType param) typing args reason


typecheckArg' :: PrimArg -> TypeSpec -> Typing -> [PrimArg] -> TypeReason ->
                 (Typing,[PrimArg])
typecheckArg' (ArgVar var _ flow ftype) paramType typing args reason =
    (addOneType reason var paramType typing, 
     ArgVar var paramType flow ftype:args)
-- XXX type specs below should include "wybe" module
typecheckArg' (ArgInt val callType) paramType typing args reason =
    typecheckArg'' callType paramType (TypeSpec [] "int" [])
                   typing args reason $ ArgInt val
typecheckArg' (ArgFloat val callType) paramType typing args reason =
    typecheckArg'' callType paramType (TypeSpec [] "float" [])
                   typing args reason $ ArgFloat val
typecheckArg' (ArgString val callType) paramType typing args reason =
    typecheckArg'' callType paramType (TypeSpec [] "string" [])
                   typing args reason $ ArgString val
typecheckArg' (ArgChar val callType) paramType typing args reason =
    typecheckArg'' callType paramType (TypeSpec [] "char" [])
                   typing args reason $ ArgChar val
                        

typecheckArg'' :: TypeSpec -> TypeSpec -> TypeSpec -> Typing -> [PrimArg] ->
                  TypeReason -> (TypeSpec -> PrimArg) -> (Typing,[PrimArg])
typecheckArg'' callType paramType constType typing args reason mkArg =
    let realType =
            if constType `subtypeOf` callType then constType else callType
    in -- trace ("check call type " ++ show callType ++ " against param type " ++ show paramType ++ " for const type " ++ show constType)
           (if paramType `subtypeOf` realType
            then typing
            else InvalidTyping1 reason,
            mkArg paramType:args)
