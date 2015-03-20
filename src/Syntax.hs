{-# LANGUAGE GADTs
           , RebindableSyntax
           , DataKinds
           , RankNTypes
           , KindSignatures
           , ScopedTypeVariables
           , FlexibleContexts
           , UndecidableInstances
           , PolyKinds
  #-}

module Syntax
       ( Zippable

         -- | Computation monad
       , Comp
       , ret
       , return
       , (>>=)
       , (>>)

         -- | Booleans, unit, sums, products, recursive types
       , true
       , false
       , unit
       , inl
       , inr
       , case_sum
       , pair
       , fst_pair
       , snd_pair
       , fold
       , unfold
       , unfold_privately
         
         -- | Arithmetic and boolean operations 
       , (+)
       , (-)
       , (*)
       , (/)
       , (&&)
       , not
       , xor
       , eq
       , exp_of_int
       , int_of_exp
       , inc
       , dec
       , fromRational
       , ifThenElse

         -- | Arrays
       , arr
       , arr2
       , arr3
       , input_arr
       , input_arr2
       , input_arr3
       , set
       , set2
       , set3
       , set4
       , get
       , get2
       , get3
       , get4

         -- | Iteration
       , iter
       , bigsum
       , times
       , forall
       , forall2
       , forall3

         -- | Top-level functions
       , input
       , sat
       , vars
       , constraints
       , result
       , the_r1cs
       , run
       , check
       , test
       ) where

import Prelude hiding 
  ( (>>)
  , (>>=)
  , (+)
  , (-)    
  , (*)    
  , (/)
  , (&&)
  , not  
  , return
  , fromRational
  , negate
  )
import qualified Prelude as P

import System.IO
  ( hFlush
  , stdout
  , hPutStrLn
  , withFile
  , IOMode( WriteMode )
  )

import Data.Typeable

import Unsafe.Coerce

import qualified Data.Map.Strict as Map
import qualified Data.IntMap.Lazy as IntMap

import Common
import Errors
import R1CS
import Source
import Compile
import Serialize

----------------------------------------------------
--
-- State Monad
--        
----------------------------------------------------        

type CompResult s a = Either ErrMsg (a,s)

data State s a = State (s -> CompResult s a)

-- | At "parse" time, we maintain an environment containing
--    (i) next_var: the next free variable
--    (ii) obj_map: a symbol table mapping (obj_var,integer index) to
--    the constraint variable associated with that object, at
--    that field index.
--  Reading from object 'a' at index 'i' (x := a_i) corresponds to:
--    (a) getting y <- obj_map(a,i)
--    (b) inserting the constraint (x = y)

type ObjMap
  = Map.Map ( Var -- object a
            , Int -- at index i
            )
            Var -- maps to variable x

data Env = Env { next_var :: Int
               , input_vars :: [Int]
               , obj_map  :: ObjMap
               , recur_level :: Int -- ^ Bounds recursion in general 
               }
           deriving Show

type Comp ty = State Env (TExp ty Rational)

runState :: State s a -> s -> CompResult s a
runState mf s = case mf of
  State f -> f s

raise_err :: ErrMsg -> Comp ty
raise_err msg = State (\_ -> Left msg)

-- | We have to define our own bind operator, unfortunately,
-- because the "result" that's returned is the sequential composition
-- of the results of 'mf', 'g' (not just whatever 'g' returns)
(>>=) :: forall (ty1 :: Ty) (ty2 :: Ty) s a.
         Typeable ty1
      => State s (TExp ty1 a)
      -> (TExp ty1 a -> State s (TExp ty2 a))
      -> State s (TExp ty2 a)
(>>=) mf g = State (\s ->
  case runState mf s of
    Left err -> Left err
    Right (e,s') ->
      case runState (g e) s' of
        Left err -> Left err
        Right (e',s'') -> Right (te_seq e e',s''))

(>>) :: forall (ty1 :: Ty) (ty2 :: Ty) s a.
        Typeable ty1
     => State s (TExp ty1 a)
     -> State s (TExp ty2 a)
     -> State s (TExp ty2 a)
(>>) mf g = do { _ <- mf; g }    

return :: a -> State s a
return e = State (\s -> Right (e,s))

ret :: a -> State s a
ret = return

inc :: Int -> Int
inc n = (P.+) n 1

dec :: Int -> Int
dec n = (P.-) n 1

-- | Allocate a new internal variable (not instantiated by user)
var :: Comp ty
var = State (\s ->
              Right ( TEVar (TVar (next_var s))
                    , s { next_var = inc (next_var s)
                        }
                    )
            )

-- | Allocate a new input variable (instantiated by user)
input :: Comp ty
input = State (\s ->
                Right ( TEVar (TVar (next_var s))
                      , s { next_var = inc (next_var s)
                          , input_vars = next_var s : input_vars s
                          }
                      )
              )

modify :: (Env -> Env) -> Comp TUnit
modify f
  = State (\s ->
            Right ( unit
                  , f s
                  )
          )

-- | Guard a (recursive) value derivation, by returning 'unit' when
-- the 'recur_level' is less than or equal 0. The 'unsafeCoerce' is
-- safe here because of the following global [TICK INVARIANT]: no
-- 'Comp' ever 'unfold's a value more than 'recur_level' times.
guard_or_unit :: Comp ty -> Comp ty
guard_or_unit f
  = State (\s ->
            case recur_level s <= 0 of
              False -> runState f s
              True -> Right ( unsafeCoerce unit
                            , s 
                            )
          )

-- | Decrement 'recur_level'.
tick :: Comp TUnit
tick = modify (\s -> s { recur_level = dec $ recur_level s })

guard :: Comp ty -> Comp ty
guard f
  = State (\s ->
            case recur_level s <= 0 of
              False -> runState f s
              True -> Left $ ErrMsg $ "ran out of fuel in state\n  "
                                      ++ show s
          )

-- | Execute computation 'mf' without modifying the overall recursion
-- budget for the remainder of the computation.
privately :: Comp ty -> Comp ty
privately mf
  = State (\s -> case runState mf s of
              Left err -> Left err
              Right (a,s') -> Right (a,s' {recur_level = recur_level s})
          )

with_fuel :: Int -> Comp ty -> Comp ty
with_fuel new_fuel mf
  = State (\s -> case runState mf (s { recur_level = new_fuel }) of
              Left err -> Left err
              Right (a,s') -> Right (a,s' {recur_level = recur_level s})
          )

iter_comp :: Typeable ty
          => Comp ty
          -> Int
          -> Comp ty
iter_comp _ 0 = raise_err $ ErrMsg "must declare >= 1 vars"
iter_comp f n =
  do { x <- f
     ; _ <- g (dec n)
     ; ret x
     }
  where g 0 = ret (TEVal VUnit)
        g m = f >> g (dec m)

----------------------------------------------------
--
-- Arrays
--        
----------------------------------------------------        

-- | Arrays: uninitialized field elements
declare_vars :: Typeable ty => Int -> Comp ty
declare_vars = iter_comp (var :: Comp ty)

-- | Like declare_vars, except vars. are marked explicitly as inputs
declare_inputs :: Typeable ty => Int -> Comp ty
declare_inputs = iter_comp (input :: Comp ty)

add_bindings :: [((Var,Int),Var)] -> Comp TUnit
add_bindings bindings
  = State (\s -> Right ( unit
                       , s { obj_map = Map.fromList bindings
                               `Map.union` (obj_map s)
                           }
                       )
          )

add_arr_mapping :: Var -> Int -> Comp TUnit
add_arr_mapping x len
  = do { let indices  = take len $ [(0::Int)..]
       ; let arr_vars = map ((P.+) x) indices
       ; add_bindings $ zip (zip (repeat x) indices) arr_vars
       }

-- | 1-d arrays. 
arr :: Typeable ty => Int -> Comp (TArr ty)
arr 0 = raise_err $ ErrMsg "array must have size > 0"
arr len
  = do { a <- declare_vars len
       ; let x = var_of_texp a
       ; _ <- add_arr_mapping x len
       ; ret $ last_seq a
       }


-- | 2-d arrays. 'width' is the size, in "bits" (#field elements), of
-- each array element.
arr2 :: Typeable ty => Int -> Int -> Comp (TArr (TArr ty))
arr2 len width
  = do { a <- arr len
       ; forall [0..dec len] (\i ->
           do { ai <- arr width
              ; set (a,i) ai
              })
       ; ret a
       }

-- | 3-d arrays.
arr3 :: Typeable ty => Int -> Int -> Int -> Comp (TArr (TArr (TArr ty)))
arr3 len width height
  = do { a <- arr2 len width
       ; forall2 ([0..dec len],[0..dec width]) (\i j ->
           do { aij <- arr height
              ; set2 (a,i,j) aij
              })
       ; ret a
       }

-- | Like 'arr', but declare array vars. as inputs.
input_arr :: Typeable ty => Int -> Comp (TArr ty)
input_arr len
  = do { a <- declare_inputs len
       ; let x = var_of_texp a
       ; _ <- add_arr_mapping x len
       ; ret $ last_seq a
       }

input_arr2 :: Typeable ty => Int -> Int -> Comp (TArr (TArr ty))
input_arr2 0 _ = raise_err $ ErrMsg "array must have size > 0"
input_arr2 len width
  = do { a <- arr len
       ; forall [0..dec len] (\i ->
           do { ai <- input_arr width
              ; set (a,i) ai
              })
       ; ret a
       }

input_arr3 :: Typeable ty => Int -> Int -> Int -> Comp (TArr (TArr (TArr ty)))
input_arr3 len width height
  = do { a <- arr2 len width
       ; forall2 ([0..dec len],[0..dec width]) (\i j ->
           do { aij <- input_arr height
              ; set2 (a,i,j) aij
              })
       ; ret a
       }

-- | Update array 'a' at position 'i' to expression 'e'.
set_addr :: Typeable ty
         => (TExp (TArr ty) Rational, Int)        
         -> TExp ty Rational   
         -> Comp TUnit
set_addr (a,i) e
  = let x = var_of_texp a
    in case last_seq e of
         scrut@(TEVar _) -> 
           do { let y = var_of_texp scrut
              ; _ <- add_bindings [((x,i),y)]
              ; ret unit
              }
           
         _ ->  
           do { le <- var
              ; let y = var_of_texp le
              ; _ <- add_bindings [((x,i),y)]
              ; ret $ TEUpdate le e
              }

set (a,i) e      = set_addr (a,i) e
set2 (a,i,j) e   = do { a' <- get (a,i); set (a',j) e }
set3 (a,i,j,k) e = do { a' <- get2 (a,i,j); set (a',k) e }
set4 (a,i,j,k,l) e = do { a' <- get3 (a,i,j,k); set (a',l) e }


get_addr :: Typeable ty => (Var,Int) -> Comp ty
get_addr (x,i)
  = State (\s -> case Map.lookup (x,i) (obj_map s) of
                   Nothing ->
                     Left
                     $ ErrMsg ("unbound var " ++ show (x,i)
                               ++ " in map " ++ show (obj_map s))
                   Just y  ->
                     Right (TEVar (TVar y), s)
          )

get :: Typeable ty => (TExp (TArr ty) Rational,Int) -> Comp ty
get (a,i)        = get_addr (var_of_texp a,i)
get2 (a,i,j)     = do { a' <- get (a,i); get (a',j) }
get3 (a,i,j,k)   = do { a' <- get2 (a,i,j); get (a',k) }
get4 (a,i,j,k,l) = do { a' <- get3 (a,i,j,k); get (a',l) }

----------------------------------------------------
--
-- Sums
--        
----------------------------------------------------        

class Derive ty where
  derive :: Comp ty

instance Derive TUnit where
  derive = ret $ TEVal VUnit

instance Derive TBool where
  derive = ret $ TEVal VFalse

instance Derive TField where
  derive = ret $ TEVal (VField 0)

instance (Typeable ty,Derive ty) => Derive (TArr ty) where
  derive
    = do { a <- arr 1
         ; v <- derive
         ; set (a,0) v
         ; ret a
         }
instance ( Typeable ty1
         , Derive ty1
         , Typeable ty2
         , Derive ty2
         )
      => Derive (TProd ty1 ty2) where
  derive
    = do { v1 <- privately derive
         ; v2 <- derive
         ; pair v1 v2
         }

instance ( Typeable ty1
         , Derive ty1
         , Typeable ty2
         , Derive ty2
         )
      => Derive (TSum ty1 ty2) where
  derive
    = do { v1 <- privately derive
         ; inl_aux v1
         }

-- [NOTE:] Must be careful to 'tick' here...otherwise we may
-- end up with infinite derived values in some cases (e.g., 'inl'
-- inside some recursive type).
instance ( Typeable f
         , Typeable (Rep f (TMu f))   
         , Derive (Rep f (TMu f))
         )
      => Derive (TMu f) where
  derive
    = do { tick
         ; v1 <- guard_or_unit derive
         ; fold v1
         }

-- 'inl' vs. 'inl_aux': 'inl' gets a fresh recursion/derivation
-- budget. And likewise for 'inr'. The reason: 'inl' is exposed to the
-- programmer. 'inl_aux' is only used internally, when deriving values
-- of sum types.
inl te1 = with_fuel fuel $ inl_aux te1

inl_aux :: forall ty1 ty2.
           ( Typeable ty1
           , Typeable ty2
           , Derive ty2
           )
        => TExp ty1 Rational
        -> Comp (TSum ty1 ty2)
inl_aux te1
  = do { x <- var
       ; v2 <- privately $ derive :: Comp ty2
       ; y <- pair te1 v2
       ; z <- pair (TEVal VFalse) y
       ; add_bindings [((var_of_texp x,0),var_of_texp z)]
       ; ret x
       }

inr_aux :: forall ty1 ty2.
           ( Typeable ty1
           , Derive ty1         
           , Typeable ty2
           )
        => TExp ty2 Rational
        -> Comp (TSum ty1 ty2)
inr_aux te2
  = do { x <- var
       ; v1 <- privately $ derive :: Comp ty1
       ; y <- pair v1 te2
       ; z <- pair (TEVal VTrue) y
       ; add_bindings [((var_of_texp x,0),var_of_texp z)]
       ; ret x
       }

inr te2 = with_fuel fuel $ inr_aux te2

case_sum :: forall ty1 ty2 ty.
            ( Typeable ty1
            , Typeable ty2
            , Typeable ty
            , Zippable ty
            )
         => (TExp ty1 Rational -> Comp ty)
         -> (TExp ty2 Rational -> Comp ty)
         -> TExp (TSum ty1 ty2) Rational
         -> Comp ty
case_sum f1 f2 e
  = do { p <- get_addr (var_of_texp e,0)
       ; b <- fst_pair p
       ; p_rest <- snd_pair p
       ; e1 <- fst_pair p_rest
       ; e2 <- snd_pair p_rest
       ; le <- privately $ f1 e1
       ; re <- f2 e2
         -- NOTE: 'zip_vals' with a fresh recursion budget here.
       ; with_fuel fuel $ zip_vals b re le
       }

class Zippable ty where
  zip_vals :: TExp TBool Rational
           -> TExp ty Rational
           -> TExp ty Rational
           -> Comp ty

instance Zippable TUnit where
  zip_vals _ _ _ = ret unit

instance Zippable TBool where
  zip_vals b b1 b2 = ret $ if b then b1 else b2

instance Zippable TField where
  zip_vals b e1 e2 = ret $ if b then e1 else e2

instance ( Zippable ty1
         , Typeable ty1
         , Zippable ty2
         , Typeable ty2
         )
      => Zippable (TProd ty1 ty2) where
  zip_vals b e1 e2
    = do { e11 <- fst_pair e1
         ; e12 <- snd_pair e1
         ; e21 <- fst_pair e2
         ; e22 <- snd_pair e2
         ; p1 <- privately $ zip_vals b e11 e21
         ; p2 <- zip_vals b e12 e22
         ; pair p1 p2
         }

instance ( Zippable ty1
         , Typeable ty1
         , Zippable ty2
         , Typeable ty2
         )
      => Zippable (TSum ty1 ty2) where
  zip_vals b e1 e2
    = do { p1 <- get_addr (var_of_texp e1,0)
                 :: Comp (TProd TBool (TProd ty1 ty2))
         ; b1 <- fst_pair p1
         ; p1_rest <- snd_pair p1
         ; e11 <- fst_pair p1_rest
         ; e12 <- snd_pair p1_rest

         ; p2 <- get_addr (var_of_texp e2,0)
         ; b2 <- fst_pair p2
         ; p2_rest <- snd_pair p2
         ; e21 <- fst_pair p2_rest
         ; e22 <- snd_pair p2_rest

         ; b' <- zip_vals b b1 b2
         ; e1' <- privately $ zip_vals b e11 e21
         ; e2' <- zip_vals b e12 e22
         ; p'' <- pair e1' e2'
         ; p' <- pair b' p''
         ; x <- var
         ; add_bindings [((var_of_texp x,0),var_of_texp p')]
         ; ret x
         }

instance ( Typeable f
         , Typeable (Rep f (TMu f))
         , Zippable (Rep f (TMu f))
         )
      => Zippable (TMu f) where
  zip_vals b e1 e2
    = do { e1' <- privately $ unsafe_unfold e1
         ; e2' <- unsafe_unfold e2
         ; x <- guard_or_unit $ zip_vals b e1' e2'
         ; fold x
         }


----------------------------------------------------
--
-- Products
--        
----------------------------------------------------        

pair :: ( Typeable ty1
        , Typeable ty2
        )
     => TExp ty1 Rational
     -> TExp ty2 Rational
     -> Comp (TProd ty1 ty2)
pair te1 te2 = go (last_seq te1) (last_seq te2)
  where go e1@(TEVar _) e2@(TEVar _)
          = do { x <- var
               ; let x1 = var_of_texp e1
               ; let x2 = var_of_texp e2             
               ; add_bindings [((var_of_texp x,0),x1)
                              ,((var_of_texp x,1),x2)]
               ; ret x
               }
        go e1@(TEVar _) e2@(_)
          = do { x <- var
               ; let x1 = var_of_texp e1
               ; x2 <- var      
               ; add_bindings [((var_of_texp x,0),x1)
                              ,((var_of_texp x,1),var_of_texp x2)]
               ; ret $ te_seq (TEUpdate x2 e2) x
               }    
        go e1@(_) e2@(TEVar _)
          = do { x <- var
               ; x1 <- var                    
               ; let x2 = var_of_texp e2
               ; add_bindings [((var_of_texp x,0),var_of_texp x1)
                              ,((var_of_texp x,1),x2)]
               ; ret $ te_seq (TEUpdate x1 e1) x
               }    
        go e1@(_) e2@(_)
          = do { x1 <- var
               ; x2 <- var
               ; x <- var
               ; add_bindings [((var_of_texp x,0),var_of_texp x1)
                              ,((var_of_texp x,1),var_of_texp x2)]
               ; ret $ te_seq (te_seq (TEUpdate x1 e1) (TEUpdate x2 e2)) x
               }

fst_pair :: ( Typeable ty1
            , Typeable ty2
            )
         => TExp (TProd ty1 ty2) Rational
         -> Comp ty1
fst_pair e = get_addr (var_of_texp e,0)

snd_pair :: ( Typeable ty1
            , Typeable ty2
            )
         => TExp (TProd ty1 ty2) Rational
         -> Comp ty2
snd_pair e = get_addr (var_of_texp e,1)

----------------------------------------------------
--
-- Recursive Types
--        
----------------------------------------------------        

-- [TICK INVARIANT:] Must tick at every 'unfold' & give up if we run
-- out of fuel.
unfold :: ( Typeable (Rep f (TMu f))
          )  
       => TExp (TMu f) Rational
       -> Comp (Rep f (TMu f))
unfold te
  = do { -- decrement 'recur_level' by one
         tick 
         -- give up here if no fuel
       ; guard $ ret (unsafeCoerce te)
       }

unsafe_unfold :: ( Typeable (Rep f (TMu f))
                 )  
              => TExp (TMu f) Rational
              -> Comp (Rep f (TMu f))
unsafe_unfold te
  = do { -- decrement 'recur_level' by one
         tick 
         -- return a value of type 'TUnit' if no fuel
       ; guard_or_unit $ ret (unsafeCoerce te)
       }

-- | Unfold 'te' without ticking the recursion budget.
-- WARNING: Don't use this operation unless you know what you're doing.
unfold_privately :: ( Typeable (Rep f (TMu f))
                    )  
                 => TExp (TMu f) Rational
                 -> Comp (Rep f (TMu f))
unfold_privately te = privately $ unfold te

fold :: ( Typeable f
        , Typeable (Rep f (TMu f))
        )
     => TExp (Rep f (TMu f)) Rational
     -> Comp (TMu f)
fold te = ret $ unsafeCoerce te
  
----------------------------------------------------
--
-- Operators, Values
--        
----------------------------------------------------        

unit :: TExp TUnit Rational
unit = TEVal VUnit 

true :: TExp TBool Rational
true = TEVal VTrue

false :: TExp TBool Rational
false = TEVal VFalse

(+) :: TExp TField Rational -> TExp TField Rational -> TExp TField Rational
(+) e1 e2 = TEBinop (TOp Add) e1 e2

(-) :: TExp TField Rational -> TExp TField Rational -> TExp TField Rational
(-) e1 e2 = TEBinop (TOp Sub) e1 e2

(*) :: TExp TField Rational -> TExp TField Rational -> TExp TField Rational
(*) e1 e2 = TEBinop (TOp Mult) e1 e2

(/) :: TExp TField Rational -> TExp TField Rational -> TExp TField Rational
(/) e1 e2 = TEBinop (TOp Div) e1 e2

(&&) :: TExp TBool Rational -> TExp TBool Rational -> TExp TBool Rational
(&&) e1 e2 = TEBinop (TOp And) e1 e2

not :: TExp TBool Rational -> TExp TBool Rational
not e = if e then false else true

xor :: TExp TBool Rational -> TExp TBool Rational -> TExp TBool Rational
xor e1 e2 = TEBinop (TOp XOr) e1 e2

eq :: TExp TBool Rational -> TExp TBool Rational -> TExp TBool Rational
eq e1 e2 = TEBinop (TOp Eq) e1 e2

fromRational :: Rational -> TExp TField Rational
fromRational r = TEVal (VField (r :: Rational))

exp_of_int :: Int -> TExp TField Rational
exp_of_int i = TEVal (VField $ fromIntegral i)

int_of_exp :: TExp TField Rational -> Int
int_of_exp e = case e of
  TEVal (VField r) -> truncate r
  _ -> fail_with $ ErrMsg $ "expected field elem " ++ show e

ifThenElse :: TExp TBool a -> TExp ty a -> TExp ty a -> TExp ty a
ifThenElse b e1 e2 = TEIf b e1 e2

----------------------------------------------------
--
-- Iteration
--        
----------------------------------------------------        

iter :: Typeable ty
     => Int
     -> (Int -> TExp ty Rational -> TExp ty Rational)
     -> TExp ty Rational
     -> TExp ty Rational
iter n f e = g n f e
  where g 0 f' e' = f' 0 e'
        g m f' e' = f' m $ g (dec m) f' e'

bigsum :: Int
       -> (Int -> TExp TField Rational)
       -> TExp TField Rational
bigsum n f = iter n (\n' e -> f n' + e) 0.0

times :: Typeable ty
      => Int
      -> Comp ty
      -> Comp TUnit
times n mf = g n mf 
  where g 0 _   = ret unit
        g m mf' = do { _ <- mf'; g (dec m) mf' }

forall :: Typeable ty
       => [a]
       -> (a -> Comp ty)
       -> Comp TUnit
forall as mf = g as mf
  where g [] _ = ret unit
        g (a : as') mf'
          = do { _ <- mf' a; g as' mf' }

forall2 (as1,as2) mf
  = forall as1 (\a1 -> forall as2 (\a2 -> mf a1 a2))
forall3 (as1,as2,as3) mf
  = forall2 (as1,as2) (\a1 a2 -> forall as3 (\a3 -> mf a1 a2 a3))

----------------------------------------------------
--
-- Toplevel Stuff 
--        
----------------------------------------------------        

data Result = 
  Result { sat :: Bool
         , vars :: Int
         , constraints :: Int
         , result :: Rational 
         , the_r1cs :: String
         }

instance Show Result where
  show (Result the_sat the_vars the_constraints the_result _)
    = "sat = " ++ show the_sat
      ++ ", vars = " ++ show the_vars
      ++ ", constraints = " ++ show the_constraints
      ++ ", result = " ++ show the_result

fuel :: Int
fuel = 5

run :: State Env a -> CompResult Env a
run mf = runState mf (Env (P.fromInteger 0) [] Map.empty fuel)

check :: Typeable ty => Comp ty -> [Rational] -> Result
check mf inputs
  = let (e,s) =
          case run mf of
            Left err -> fail_with err
            Right x -> x
        nv       = next_var s
        in_vars  = reverse $ input_vars s
        r1cs     = r1cs_of_exp nv in_vars e
        r1cs_string = serialize_r1cs r1cs
        nw        = r1cs_num_vars r1cs
        f         = r1cs_gen_witness r1cs . IntMap.fromList
        [out_var] = r1cs_out_vars r1cs
        ng  = num_constraints r1cs
        wit = case length in_vars /= length inputs of
                True ->
                  fail_with
                  $ ErrMsg ("expected " ++ show (length in_vars) ++ " input(s)"
                            ++ " but got " ++ show (length inputs) ++ " input(s)")
                False ->
                  f (zip in_vars inputs)
        out = case IntMap.lookup out_var wit of
                Nothing ->
                  fail_with
                  $ ErrMsg ("output variable " ++ show out_var
                            ++ "not mapped, in\n  " ++ show wit)
                Just out_val -> out_val
    in Result (sat_r1cs wit r1cs) nw ng out r1cs_string

-- | (1) Compile to R1CS.
--   (2) Generate a satisfying assignment, w.
--   (3) Check whether 'w' satisfies the constraint system produced in (1).
--   (4) Check that results match.
do_test :: Typeable ty => (Comp ty, [Rational], Rational) -> IO ()
do_test (prog,inputs,res) =
  let print_ln             = print_ln_to_file stdout
      print_ln_to_file h s = (P.>>) (hPutStrLn h s) (hFlush h)
      print_to_file s
        = withFile "test_cs_in.ppzksnark" WriteMode (flip print_ln_to_file s)
  in case check prog inputs of
    r@(Result True _ _ res' r1cs_string) ->
      case res == res' of
        True  ->  (P.>>) (print_to_file r1cs_string) (print_ln $ show r)
        False ->  print_ln $ show $ "error: results don't match: "
                  ++ "expected " ++ show res ++ " but got " ++ show res'
    Result False _ _ _ _ ->
      print_ln $ "error: witness failed to satisfy constraints"

test :: Typeable ty => (Comp ty,[Int],Integer) -> IO ()
test (prog,args,res)
  = do_test (prog,map fromIntegral args,fromIntegral res)
