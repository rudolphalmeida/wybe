{-# OPTIONS -XTupleSections #-}
--  File     : Normalise.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Fri Jan  6 11:28:23 2012
--  Purpose  : Convert parse tree into AST
--  Copyright: (c) 2012 Peter Schachte.  All rights reserved.

-- |Support for normalising wybe code as parsed to a simpler form
--  to make compiling easier.
module Normalise (normalise, normaliseItem) where

import AST
import Config (wordSize,tagMask)
import Control.Monad
import Control.Monad.State (gets)
import Control.Monad.Trans (lift,liftIO)
import Data.List as List
import Data.Map as Map
import Data.Maybe
import Data.Set as Set
import Flatten
import Options (optUseStd)
import Config (wordSize,wordSizeBytes)
import Snippets

-- |Normalise a list of file items, storing the results in the current module.
normalise :: ([ModSpec] -> Compiler ()) -> [Item] -> Compiler ()
normalise modCompiler items = do
    mapM_ (normaliseItem modCompiler) items
    -- liftIO $ putStrLn "File compiled"
    -- every module imports stdlib
    useStdLib <- gets (optUseStd . options)
    when useStdLib $ addImport ["wybe"] (ImportSpec (Just Set.empty) Nothing)
    -- Now generate main proc if needed
    stmts <- getModule stmtDecls 
    unless (List.null stmts)
      $ normaliseItem modCompiler 
            (ProcDecl Public Det False (ProcProto "" [] initResources) 
                          (List.reverse stmts) Nothing)

-- |The resources available at the top level
-- XXX this should be all resources with initial values
initResources :: [ResourceFlowSpec]
-- initResources = [ResourceFlowSpec (ResourceSpec ["wybe"] "io") ParamInOut]
initResources = [ResourceFlowSpec (ResourceSpec ["wybe","io"] "io") ParamInOut]


-- |Normalise a single file item, storing the result in the current module.
normaliseItem :: ([ModSpec] -> Compiler ()) -> Item -> Compiler ()
normaliseItem modCompiler (TypeDecl vis (TypeProto name params) rep items pos) 
  = do
    let (rep', ctorVis, consts, nonconsts) = normaliseTypeImpln rep
    ty <- addType name (TypeDef (length params) rep' pos) vis
    -- XXX Should we special-case handling of = instead of generating these:
    let eq1 = assignmentProc ty False
    let eq2 = assignmentProc ty True
    modspec <- getModuleSpec
    let typespec = TypeSpec modspec name
                   $ List.map (\n->TypeSpec [] n []) params
    let constCount = length consts
    let nonConstCount = length nonconsts
    updateImplementation (\imp -> imp { modConstCtorCount = constCount,
                                        modNonConstCtorCount = nonConstCount })
    let constItems =
          concatMap (constCtorItems ctorVis typespec) $ zip consts [0..]
    nonconstItems <- fmap concat $
           mapM (nonConstCtorItems ctorVis typespec constCount nonConstCount)
           $ zip nonconsts [0..]
    let extraItems = implicitItems typespec consts nonconsts items
    normaliseSubmodule modCompiler name (Just params) vis pos
      $ [eq1,eq2] ++ constItems ++ nonconstItems ++ items ++ extraItems
normaliseItem modCompiler (ModuleDecl vis name items pos) = do
    normaliseSubmodule modCompiler name Nothing vis pos items
normaliseItem _ (ImportMods vis modspecs pos) = do
    mapM_ (\spec -> addImport spec (importSpec Nothing vis)) modspecs
normaliseItem _ (ImportItems vis modspec imports pos) = do
    addImport modspec (importSpec (Just imports) vis)
normaliseItem _ (ResourceDecl vis name typ init pos) =
  addSimpleResource name (SimpleResource typ init pos) vis
normaliseItem modCompiler (FuncDecl vis detism inline 
                           (FnProto name params resources) 
                           resulttype result pos) =
  let flowType = Implicit pos
  in  normaliseItem modCompiler
   (ProcDecl
    vis detism inline
    (ProcProto name (params ++ [Param "$" resulttype ParamOut flowType]) 
     resources)
    [maybePlace
     (case resulttype of
           Unspecified -> 
             ForeignCall "llvm" "move" []
             [result, Unplaced $ Var "$" ParamOut flowType]
           _ ->
             ForeignCall "llvm" "move" []
             [maybePlace (Typed (content result) resulttype False)
              $ place result,
              Unplaced $ Typed (Var "$" ParamOut flowType) resulttype False])
     pos]
    pos)
normaliseItem _ item@(ProcDecl _ _ _ _ _ _) = addProc 0 item
normaliseItem _ (StmtDecl stmt pos) = do
    updateModule (\s -> s { stmtDecls = maybePlace stmt pos : stmtDecls s})



normaliseSubmodule :: ([ModSpec] -> Compiler ()) -> Ident -> 
                      Maybe [Ident] -> Visibility -> OptPos -> 
                      [Item] -> Compiler ()
normaliseSubmodule modCompiler name typeParams vis pos items = do
    dir <- getDirectory
    parentModSpec <- getModuleSpec
    let subModSpec = parentModSpec ++ [name]
    addImport subModSpec (importSpec Nothing vis)
    -- Add the submodule to the submodule list of the implementation
    updateImplementation $
        updateModSubmods (\sm-> Map.insert name subModSpec sm)
    enterModule dir subModSpec typeParams
    case typeParams of
      Nothing -> return ()
      Just _ ->
        updateImplementation 
        (\imp ->
          let set = Set.singleton $ TypeSpec parentModSpec name []
          in imp { modKnownTypes = Map.insert name set $ modKnownTypes imp })
    normalise modCompiler items
    mods <- exitModule
    unless (List.null mods) $ modCompiler mods
    return ()



----------------------------------------------------------------
--                Generating code for type declarations
----------------------------------------------------------------


-- |Given a type implementation, return the low-level type, the visibility
--  of its constructors, and the constructors divided into constant (arity 0)
--  and non-constant ones.
normaliseTypeImpln :: TypeImpln ->
                      (TypeRepresentation,Visibility,
                       [Placed FnProto],[Placed FnProto])
normaliseTypeImpln (TypeRepresentation repName) =
    (normaliseTypeRepresntation repName, Private, [], [])
normaliseTypeImpln (TypeCtors vis ctors) =
    let (constCtrs,nonConstCtrs) =
            List.partition ((==0) . length . fnProtoParams . content) ctors
    in ((if List.null nonConstCtrs
         then "i" ++
              (show $ ceiling $ logBase 2 $ fromIntegral $ length constCtrs)
         else "pointer"),
        vis,constCtrs,nonConstCtrs)


normaliseTypeRepresntation :: String -> String
normaliseTypeRepresntation "int" = "i" ++ show wordSize
normaliseTypeRepresntation "float" = "f" ++ show wordSize
normaliseTypeRepresntation "double" = "f64"
normaliseTypeRepresntation other = other


-- |Generate an assignment proc (a definition of '=')
assignmentProc :: TypeSpec -> Bool -> Item
assignmentProc ty leftToRight =
    let (lname,lflow,rname,rflow)
            = if leftToRight
              then ("in", ParamIn,"out", ParamOut)
              else ("out", ParamOut,"in", ParamIn)
    in ProcDecl Public Det True
       (ProcProto "=" [Param lname ty lflow Ordinary,
                       Param rname ty rflow Ordinary] [])
       [move (varGet "in") (varSet "out")]
       Nothing


-- |All items needed to implement a const contructor for the specified type.
constCtorItems :: Visibility -> TypeSpec -> (Placed FnProto,Integer) -> [Item]
constCtorItems  vis typeSpec (placedProto,num) =
    let pos = place placedProto
        constName = fnProtoName $ content placedProto
    in [ProcDecl vis Det True
        (ProcProto constName [Param "$" typeSpec ParamOut Ordinary] [])
        [lpvmCastToVar (castTo (IntValue num) typeSpec) "$"] pos,
        ProcDecl vis SemiDet True
        (ProcProto constName [Param "$" typeSpec ParamIn Ordinary] [])
        [Unplaced $ Test []
         (comparisonExp "eq"
          (lpvmCastExp (varGet "$") intType)
          (intCast $ IntValue num))]
        pos]


-- |All items needed to implement a non-const contructor for the specified type.
-- XXX need to handle the case of too many constructors for the number of tag
-- bits available
nonConstCtorItems :: Visibility -> TypeSpec -> Int -> Int
                  -> (Placed FnProto,Integer) -> Compiler [Item]
nonConstCtorItems vis typeSpec constCount nonConstCount (placedProto,tag) = do
    let pos = place placedProto
    let ctorName = fnProtoName $ content placedProto
    let params = fnProtoParams $ content placedProto
    fields <- mapM (\(Param var typ _ _) -> fmap (var,typ,) $ fieldSize typ)
              params
    let (fields',size) = 
          List.foldl (\(lst,offset) (var,typ,sz) ->
                       let aligned = alignOffset offset sz
                       in (((var,typ,aligned):lst),aligned + sz))
          ([],0) fields
    return 
      $ constructorItems ctorName params typeSpec size fields' tag pos
      ++ deconstructorItems ctorName params typeSpec constCount nonConstCount
         fields' tag pos
      ++ concatMap (getterSetterItems vis typeSpec ctorName pos
                    constCount nonConstCount tag) fields'


-- |The number of bytes occupied by a value of the specified type.  If the
--  type is boxed, this is the word size.
fieldSize :: TypeSpec -> Compiler Int
fieldSize _ = return wordSizeBytes

-- |The number of bytes occupied by a value of the specified type.  This is
--  the actual size of a value of the type, regardless of boxing.
-- typeSize :: TypeSpec -> Compiler Int


-- |Given a tentative offset into a structure and the size of the thing at 
--  that offset, return the appropriate actual offset based on the size.
--  Our approach is never to align anything on more than a word size
--  boundary, anything bigger than that is aligned to the word size.
--  For smaller things 
alignOffset :: Int -> Int -> Int
alignOffset offset size =
    let alignment = if size > wordSizeBytes
                    then wordSizeBytes
                    else fromJust $ find ((0==) . (size`mod`)) $ 
                         reverse $ List.map (2^) 
                         [0..floor $ logBase 2 $ fromIntegral wordSizeBytes]
    in ((offset + alignment - 1) `div` alignment) * alignment


constructorItems :: Ident -> [Param] -> TypeSpec -> Int 
                    -> [(Ident,TypeSpec,Int)] -> Integer -> OptPos -> [Item]
constructorItems ctorName params typeSpec size fields tag pos =
    let flowType = Implicit pos
    in [ProcDecl Public Det True
        (ProcProto ctorName (params++[Param "$" typeSpec ParamOut Ordinary]) [])
        ([Unplaced $ ForeignCall "lpvm" "alloc" []
          [Unplaced $ IntValue $ fromIntegral size,
           Unplaced $ Typed (varSet "$rec") typeSpec True]]
         ++
         (reverse $ List.map (\(var,_,aligned) ->
                               (Unplaced $ ForeignCall "lpvm" "mutate" []
                                [Unplaced $ Var "$rec" ParamInOut flowType,
                                 Unplaced $ IntValue $ fromIntegral aligned,
                                 Unplaced $ Var var ParamIn flowType]))
          fields)
         ++
         [lpvmCast (varGet "$rec") "$recint" intType,
          Unplaced $ ForeignCall "llvm" "or" []
          [Unplaced $ varGet "$recint",
           Unplaced $ IntValue $ fromIntegral tag,
           Unplaced $ intCast (varSet "$recinttagged")],
          lpvmCastToVar (varGet "$recinttagged") "$"])
        pos]


deconstructorItems :: Ident -> [Param] -> TypeSpec -> Int -> Int
                    -> [(Ident,TypeSpec,Int)] -> Integer -> OptPos -> [Item]
deconstructorItems ctorName params typeSpec constCount nonConstCount
    fields tag pos =
    -- XXX this needs to take the tag into account
    -- XXX this needs to be able to fail if the constructor doesn't match
    let flowType = Implicit pos
        detism = if constCount + nonConstCount > 1 then SemiDet else Det
    in [ProcDecl Public detism True
        (ProcProto ctorName 
         (List.map (\(Param n t _ ft) -> (Param n t ParamOut ft)) params
          ++ [Param "$" typeSpec ParamIn Ordinary]) 
         [])
        ((tagCheck constCount nonConstCount tag "$") ++
        (reverse $ List.map (\(var,_,aligned) ->
                              (Unplaced $ ForeignCall "lpvm" "access" []
                               [Unplaced $ Var "$" ParamIn flowType,
                                Unplaced $ IntValue $ fromIntegral aligned,
                                Unplaced $ Var var ParamOut flowType]))
         fields))
        pos]


-- |Generate the needed Test statements to check that the tag of the value
--  of the specified variable matches the specified tag
tagCheck :: Int -> Int -> Integer -> Ident -> [Placed Stmt]
tagCheck constCount nonConstCount tag varName =
    -- If there are any constant constructors, be sure it's not one of them
    (case constCount of
          0 -> []
          _ -> [Unplaced
                $ Test []
                (comparisonExp "uge"
                 (lpvmCastExp (varGet varName) intType)
                 (intCast $ iVal constCount))])
     ++
     (case nonConstCount of
           1 -> []  -- Nothing to do if it's the only non-const constructor
           _ -> [Unplaced $ Test []
                 (comparisonExp "eq"
                  (intCast $ ForeignFn "llvm" "and" []
                   [Unplaced $ lpvmCastExp (varGet varName) intType,
                    Unplaced $ iVal tagMask])
                  (intCast $ iVal tag))])


-- | Produce a getter and a setter for one field of the specified type.
getterSetterItems :: Visibility -> TypeSpec -> Ident -> OptPos 
                     -> Int -> Int -> Integer -> (VarName,TypeSpec,Int)
                     -> [Item]
getterSetterItems vis rectype ctorName pos constCount nonConstCount tag
    (field,fieldtype,offset) =
    -- XXX need to take tag into account!
    -- XXX this needs to be able to fail if the constructor doesn't match
    [ProcDecl vis Det True
     (ProcProto field [Param "$rec" rectype ParamIn Ordinary,
                       Param "$" fieldtype ParamOut Ordinary] [])
     ((tagCheck constCount nonConstCount tag "$rec")
      ++ [Unplaced $ ForeignCall "lpvm" "access" []
          [Unplaced $ varGet "$rec",
           Unplaced $ IntValue $ fromIntegral offset,
           Unplaced $ varSet "$"]])
      pos,
      ProcDecl vis Det True
      (ProcProto field
       [Param "$rec" rectype ParamInOut Ordinary,
        Param "$field" fieldtype ParamIn Ordinary] [])
      ((tagCheck constCount nonConstCount tag "$rec")
      ++ [Unplaced $ ForeignCall "lpvm" "mutate" []
          [Unplaced $ varGet "$rec",
           Unplaced $ IntValue $ fromIntegral offset,
           Unplaced $ varGet "$field",
           Unplaced $ varSet "$rec"]])
     pos]


----------------------------------------------------------------
--                     Generating implicit procs
--
-- Wybe automatically generates equality test procs if you don't write
-- your own definitions.
--
----------------------------------------------------------------

implicitItems :: TypeSpec -> [Placed FnProto] -> [Placed FnProto] -> [Item]
                 -> [Item]
implicitItems typespec consts nonconsts items =
    implicitEquality typespec consts nonconsts items
    -- XXX add print, display, maybe prettyprint, and lots more


implicitEquality :: TypeSpec -> [Placed FnProto] -> [Placed FnProto] -> [Item]
                 -> [Item]
implicitEquality typespec consts nonconsts items =
    if List.any equalityTest items || consts==[] && nonconsts==[]
    then [] -- don't generate if user-defined or if no constructors at all
    else
      let proto = ProcProto "=" [Param "$left" typespec ParamIn Ordinary,
                                 Param "$right" typespec ParamIn Ordinary] []
          body = equalityBody consts nonconsts
      in [ProcDecl Public SemiDet True proto body Nothing]

-- |Does the item declare an = test or function?
equalityTest :: Item -> Bool
equalityTest (ProcDecl _ SemiDet _ (ProcProto "=" [_,_] _) _ _) = True
equalityTest (FuncDecl _ Det _ (FnProto "=" [_,_] _) _ _ _) = True
equalityTest _ = False


-- | Generate the body of an equality test proc given the const and
--   non-const constructors.
--   Our strategy is:
--       if there are no non-consts, just compare the values; otherwise
--       if there are any consts, generate code to check if the value
--       of the first is less than the number of consts, and if so, return
--       whether or not the two values are equal.  If there are no consts,
--       or if the value is not less than the number, then generate one
--       test per non-const constructor.  Each test checks if the tag of
--       the first argument is the tag for that constructor (unless there
--       is exactly one non-const constructor, in which case skip the test),
--       and then test each field for equality by calling the = test.
--
--       XXX this needs to check that there are not too many non-const
--       constructors for the number of available tag bits.
equalityBody :: [Placed FnProto] -> [Placed FnProto] -> [Placed Stmt]
equalityBody [] [] = shouldnt "trying to generate = test with no constructors"
equalityBody consts [] = equalityConsts consts
equalityBody consts nonconsts =
    [Unplaced $ Cond [] (comparisonExp "ult" (intCast $ varGet "$left")
                         (iVal $ length consts))
     (equalityConsts consts)
     -- XXX temporarily:
     -- []]
     --  XXX should be:
     (equalityNonconsts nonconsts consts)]


-- |Return code to check of two const values values are equal, given that we
--  know that the values are not non-consts.
equalityConsts :: [Placed FnProto] -> [Placed Stmt]
equalityConsts [] = []
equalityConsts _ =
    [Unplaced $ Test [] (comparisonExp "eq" (intCast $ varGet "$left")
                         (intCast $ varGet "$right"))]

-- |Return code to check that two values are equal when the first is known
--  not to be a const constructor.
equalityNonconsts :: [Placed FnProto] -> [Placed FnProto] -> [Placed Stmt]
equalityNonconsts [] _ =
    shouldnt "type with no non-const constructors should have been handled"
equalityNonconsts [single] [] =
    let FnProto name params _ = content single
    in  deconstructCall name "$left" params False
        ++ deconstructCall name "$right" params False
        ++ concatMap equalityField params
equalityNonconsts [single] (_:_) =
    let FnProto name params _ = content single
    in  [Unplaced $ Test (deconstructCall name "$left" params True)
         $ Unplaced $ varGet "$left$",
         Unplaced $ Test (deconstructCall name "$right" params True)
         $ Unplaced $ varGet "$right$"]
        ++
        concatMap equalityField params
equalityNonconsts ctrs _ = nyi "multiple non-const constructors"


deconstructCall :: Ident -> Ident -> [Param] -> Bool -> [Placed Stmt]
deconstructCall ctor arg params isTest =
    [Unplaced $ ProcCall [] ctor Nothing
     $ List.map (\p -> Unplaced $ varSet $ arg++"$"++paramName p) params
     ++ [Unplaced $ varGet arg]
     ++ if isTest then [Unplaced $ varSet $ arg++"$"] else []]

-- |Return code to check that one field of two data are equal, when
--  they are known to have the same constructor.
equalityField :: Param -> [Placed Stmt]
equalityField param =
    let field = paramName param
        leftField = "$left$"++field
        rightField = "$right$"++field
    in  [Unplaced $ Test []
         (Unplaced $ Fncall [] "="
          [Unplaced $ varGet leftField,
           Unplaced $ varGet rightField])]
