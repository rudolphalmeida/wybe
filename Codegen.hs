-- File    : Codegen.hs
-- RCS     : $Id$
-- Author  : Ashutosh Rishi Ranjan
-- Purpose : Generate and emit LLVM from basic blocks of a module

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}

module Codegen (
  Codegen(..), LLVM(..), CodegenState(..), BlockState(..),
  emptyModule, runLLVM, execCodegen,
  -- * Blocks
  createBlocks, setBlock, addBlock, entryBlockName,
  call, externf, ret, globalDefine,
  -- * Symbol storage
  alloca, store, local, assign, load, getVar, localVar,
  -- * Types
  int_t, phantom_t, float_t, char_t, ptr_t,
  -- * Instructions
  instr, namedInstr,
  iadd, isub, imul, idiv, fadd, fsub, fmul, fdiv, sdiv,
  cons, uitofp, fptoui,
  -- * Testing
  showSymbolTable
  ) where

import           Data.Function
import           Data.List
import qualified Data.Map                                as Map
import           Data.String
import           Data.Word

import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.State

import           LLVM.General.AST
import qualified LLVM.General.AST                        as LLVMAST
import           LLVM.General.AST.Global

import           LLVM.General.AST.AddrSpace
import qualified LLVM.General.AST.Attribute              as A
import qualified LLVM.General.AST.CallingConvention      as CC
import qualified LLVM.General.AST.Constant               as C
import qualified LLVM.General.AST.FloatingPointPredicate as FP
import qualified LLVM.General.AST.IntegerPredicate       as IP

import           LLVM.General.Context
import           LLVM.General.Module

-- A LLVM function consists of a sequence of basic blocks containing a
-- sequence of instructions and assignment to local values. During
-- compilation basic blocks will roughly correspond to labels in the
-- native assembly output.

-- Some simple type synonyms
type SymbolTable = [(String, Operand)]
type Names = Map.Map String Int

----------------------------------------------------------------------------
-- Types                                                                  --
----------------------------------------------------------------------------

int_t :: Type
int_t = IntegerType 32

ptr_t :: Type -> Type
ptr_t ty = PointerType ty (AddrSpace 0)

phantom_t :: Type
phantom_t = VoidType

float_t :: Type
float_t = FloatingPointType 32 IEEE

char_t :: Type
char_t = IntegerType 8

----------------------------------------------------------------------------
-- Codegen State                                                          --
----------------------------------------------------------------------------


-- | 'CodegenState' will generate the toplevel module code
data CodegenState
    = CodegenState {
        currentBlock :: Name                    -- ^ Name of the active block to append to
      , blocks       :: Map.Map Name BlockState -- ^ Blocks for function
      , symtab       :: SymbolTable             -- ^ Local symbol table of a function
      , blockCount   :: Int                     -- ^ Incrementing count of basic blocks
      , count        :: Word                    -- ^ Count for temporary operands
      , names        :: Names                   -- ^ Name supply
      } deriving Show

-- | 'BlockState' will generate the code for basic blocks inside of
-- function definitions
data BlockState
    = BlockState {
        idx   :: Int -- ^ Block
      , stack :: [Named Instruction]
      , term  :: Maybe (Named Terminator)
      } deriving Show


-- | The 'Codegen' state monad will hold the state of the code generator
-- That is, a map of block names to their 'BlockState' representation
newtype Codegen a = Codegen { runCodegen :: State CodegenState a }
    deriving (Functor, Applicative, Monad, MonadState CodegenState)


-- | Gets a new count suffix for a temporary local operands
fresh :: Codegen Word
fresh = do
  ix <- gets count
  modify $ \s -> s { count = 1 + ix }
  return (ix + 1)


showSymbolTable :: Codegen String
showSymbolTable =
    do tab <- gets symtab
       return (show tab)

----------------------------------------------------------------------------
-- LLVM State Monad                                                       --
----------------------------------------------------------------------------

-- | The 'LLVM' state monad holds code for the LLVM module and will be
-- evaluated to emit llvm-general module contatining the AST
newtype LLVM a = LLVM { unLLVM :: State LLVMAST.Module a }
    deriving (Functor, Applicative, Monad, MonadState LLVMAST.Module)

runLLVM :: LLVMAST.Module -> LLVM a -> LLVMAST.Module
runLLVM = flip (execState . unLLVM)

emptyModule :: String -> LLVMAST.Module
emptyModule label = defaultModule { moduleName = label }

-- | Add a definition to the AST.Module (LLVMAST.Module qualified),
-- to the field moduleDefinitions
addDefn :: Definition -> LLVM ()
addDefn d = do
  defs <- gets moduleDefinitions
  modify $ \s -> s { moduleDefinitions = defs ++ [d] }



globalDefine :: Type -> String -> [(Type, Name)] -> [BasicBlock] -> Definition
globalDefine rettype label argtypes body
             = GlobalDefinition $ functionDefaults {
                 name = Name label
               , parameters = ([Parameter ty nm [] | (ty, nm) <- argtypes], False)
               , returnType = rettype
               , basicBlocks = body
               }

-- | 'external' records extern definitions
external :: Type -> String -> [(Type, Name)] -> [BasicBlock] -> LLVM ()
external rettype label argtypes body
    = addDefn $ GlobalDefinition $ functionDefaults {
        name = Name label
      , parameters = ([Parameter ty nm [] | (ty, nm) <- argtypes], False)
      , returnType = rettype
      , basicBlocks = body
      }


----------------------------------------------------------------------------
-- Blocks                                                                 --
----------------------------------------------------------------------------

entry :: Codegen Name
entry = gets currentBlock

entryBlockName :: String
entryBlockName = "entry"

-- | Initializes an empty new block
emptyBlock :: Int -> BlockState
emptyBlock i = BlockState i [] Nothing

emptyCodegen :: CodegenState
emptyCodegen = CodegenState (Name entryBlockName) Map.empty [] 1 0 Map.empty

execCodegen :: Codegen a -> CodegenState
execCodegen m = execState (runCodegen m) emptyCodegen


-- | 'addBlock' creates and adds a new block to the current blocks
addBlock :: String -> Codegen Name
addBlock bname = do
  -- Retrieving the current field values
  blks <- gets blocks
  ix <- gets blockCount
  ns <- gets names
  let new = emptyBlock ix
      (qname, supply) = uniqueName bname ns
  -- updating with new block appended
  modify $ \s -> s { blocks = Map.insert (Name qname) new blks
                   , blockCount = ix + 1
                   , names = supply
                   }
  return (Name qname)

setBlock :: Name -> Codegen Name
setBlock bname =
    do modify $ \s -> s { currentBlock = bname }
       return bname

-- | Get the current block.
getBlock :: Codegen Name
getBlock = gets currentBlock


-- | Replace the current block with a 'new' block
modifyBlock :: BlockState -> Codegen ()
modifyBlock new = do
  active <- gets currentBlock
  modify $ \s -> s { blocks = Map.insert active new (blocks s) }


-- | Find the current block in the list of blocks (Map of blocks)
current :: Codegen BlockState
current = do
  curr <- gets currentBlock
  blks <- gets blocks
  case Map.lookup curr blks of
    Just x -> return x
    Nothing -> error $ "No such block found: " ++ show curr


createBlocks :: CodegenState -> [BasicBlock]
createBlocks m = map makeBlock $ sortBlocks $ Map.toList (blocks m)

makeBlock :: (Name, BlockState) -> BasicBlock
makeBlock (l, (BlockState _ s t)) = BasicBlock l s (maketerm t)
  where
    maketerm (Just x) = x
    maketerm Nothing = error $ "Block has no terminator: " ++ (show l)

sortBlocks :: [(Name, BlockState)] -> [(Name, BlockState)]
sortBlocks = sortBy (compare `on` (idx . snd))

----------------------------------------------------------------------------
-- Names supply                                                           --
----------------------------------------------------------------------------

-- | 'uniqueName' checks a name supply to generate a unique name by
-- adding a number suffix (which is incremental) to a name which has already
-- been used.
uniqueName :: String -> Names -> (String, Names)
uniqueName nm ns =
    case Map.lookup nm ns of
      Nothing -> (nm, Map.insert nm 1 ns)
      Just ix -> (nm ++ show ix, Map.insert nm (ix + 1) ns)


----------------------------------------------------------------------------
-- Name Referencing                                                       --
----------------------------------------------------------------------------

-- | Local references (prefixed with % in LLVM)
local :: Type -> Name -> Operand
local ty nm = LocalReference ty nm


-- | Refer to toplevel functions (prefixed with @ in LLVM)
externf :: Type -> Name -> Operand
externf ty = ConstantOperand . (C.GlobalReference ty)

-- | Create a local variable of the given type
localVar :: Type -> String -> Operand
localVar t s =  (LocalReference t ) $ LLVMAST.Name s

----------------------------------------------------------------------------
-- Symbol Table                                                           --
----------------------------------------------------------------------------

assign :: String -> Operand -> Codegen ()
assign var x = do
  lcls <- gets symtab
  modify $ \s -> s { symtab = (var, x) : lcls }

getVar :: String -> Codegen Operand
getVar var = do
  lcls <- gets symtab
  case lookup var lcls of
    Just x -> return x
    Nothing -> error $ "Local variable not in scope: " ++ show var


----------------------------------------------------------------------------
-- Instructions                                                           --
----------------------------------------------------------------------------

-- | The `namedInstr` function appends a named instruction into the instruction
-- stack of the current BasicBlock. This action also produces a Operand value
-- of the given type (this will be the result type of performing that instruction).
namedInstr :: Type -> String -> Instruction -> Codegen Operand
namedInstr ty nm ins =
    do let ref = Name nm
       blk <- current
       let i = stack blk
       modifyBlock $ blk { stack = i ++ [ref := ins] }
       return $ local ty ref

-- | The `instr` function appends an unnamed instruction intp the instruction stack
-- of the current BasicBlock. The temp name is generated using a fresh word counter.
instr :: Type -> Instruction -> Codegen Operand
instr ty ins =
    do n <- fresh
       let ref = UnName n
       blk <- current
       let i = stack blk
       modifyBlock $ blk { stack = i ++ [ref := ins] }
       return $ local ty ref


-- | 'terminator' provides the last instruction of a basic block.
terminator :: Named Terminator -> Codegen (Named Terminator)
terminator trm = do
  blk <- current
  modifyBlock $ blk { term = Just trm }
  return trm


-- Some basic instructions

toArgs :: [Operand] -> [(Operand, [A.ParameterAttribute])]
toArgs xs = map (\x -> (x, [])) xs

-- * Integer arithmetic operations

iadd :: Operand -> Operand -> Instruction
iadd a b = Add False False a b []

isub :: Operand -> Operand -> Instruction
isub a b = Sub False False a b []

imul :: Operand -> Operand -> Instruction
imul a b = Mul False False a b []

idiv :: Operand -> Operand -> Instruction
idiv a b = UDiv True a b []

sdiv :: Operand -> Operand -> Instruction
sdiv a b = SDiv True a b []

-- * Floating point arithmetic operations

fadd :: Operand -> Operand -> Instruction
fadd a b = FAdd NoFastMathFlags a b []

fsub :: Operand -> Operand -> Instruction
fsub a b = FSub NoFastMathFlags a b []

fmul :: Operand -> Operand -> Instruction
fmul a b = FMul NoFastMathFlags a b []

fdiv :: Operand -> Operand -> Instruction
fdiv a b = FDiv NoFastMathFlags a b []

-- * Comparisions

fcmp :: FP.FloatingPointPredicate -> Operand -> Operand -> Instruction
fcmp p a b = FCmp p a b []

icmp :: IP.IntegerPredicate -> Operand -> Operand -> Instruction
icmp p a b = ICmp p a b []

-- * Unary

uitofp :: Operand -> Instruction
uitofp a = UIToFP a float_t []

fptoui :: Operand -> Instruction
fptoui a = FPToUI a int_t []

cons :: C.Constant -> Operand
cons = ConstantOperand



-- TODO: Look into all the arithmetic instructions and what they actually do.

-- * Effect instructions

-- | The 'call' instruction represents a simple function call.
-- TODO: Look into and make a TCO version of the function
-- TODO: Look into calling conventions (is fast cc alright?)
call :: Operand -> [Operand] -> Instruction
call fn args = Call False CC.C [] (Right fn) (toArgs args) [] []

-- | The ‘alloca‘ function wraps LLVM's alloca instruction. The 'alloca'
-- instruction is pushed on the instruction stack (unnamed) and referenced with
-- a *type operand.
-- The Alloca LLVM instruction allocates memory on the stack frame of the
-- currently executing function, to be automatically released when this
-- function returns to its caller.
alloca :: Type -> Instruction
alloca ty = Alloca ty Nothing 0 []

-- | The 'store' instruction is used to write to write to memory. yields void.
store :: Operand -> Operand -> Codegen Operand
store ptr val = instr phantom_t $ Store False ptr val Nothing 0 []

-- | The 'load' function wraps LLVM's load instruction with defaults.
load :: Operand -> Instruction
load ptr = Load False ptr Nothing 0 []


-- * Control Flow operations

-- TODO: These have to be wrapped according to how LPVM functions

br :: Name -> Codegen (Named Terminator)
br val = terminator $ Do $ Br val []

cbr :: Operand -> Name -> Name -> Codegen (Named Terminator)
cbr cond tr fl = terminator $ Do $ CondBr cond tr fl []

ret :: Operand -> Codegen (Named Terminator)
ret val = terminator $ Do $ Ret (Just val) []
