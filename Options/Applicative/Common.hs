{-# LANGUAGE Rank2Types #-}
module Options.Applicative.Common (
  -- * Option parsers
  --
  -- | A 'Parser' is composed of a list of options. Several kinds of options
  -- are supported:
  --
  --  * Flags: simple no-argument options. When a flag is encountered on the
  --  command line, its value is returned.
  --
  --  * Options: options with an argument. An option can define a /reader/,
  --  which converts its argument from String to the desired value, or throws a
  --  parse error if the argument does not validate correctly.
  --
  --  * Arguments: positional arguments, validated in the same way as option
  --  arguments.
  --
  --  * Commands. A command defines a completely independent sub-parser. When a
  --  command is encountered, the whole command line is passed to the
  --  corresponding parser.
  --
  Parser,
  liftOpt,
  showOption,

  -- * Program descriptions
  --
  -- A 'ParserInfo' describes a command line program, used to generate a help
  -- screen. Two help modes are supported: brief and full. In brief mode, only
  -- an option and argument summary is displayed, while in full mode each
  -- available option and command, including hidden ones, is described.
  --
  -- A basic 'ParserInfo' with default values for fields can be created using
  -- the 'info' function.
  --
  -- A 'ParserPrefs' contains general preferences for all command-line
  -- options, and can be built with the 'prefs' function.
  ParserInfo(..),
  ParserPrefs(..),

  -- * Running parsers
  runParserInfo,
  runParserFully,
  runParser,
  evalParser,

  -- * Low-level utilities
  mapParser,
  treeMapParser,
  optionNames
  ) where

import Control.Applicative
import Control.Monad (guard, mzero, msum, when, liftM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (StateT(..), get, put, runStateT)
import Data.List (isPrefixOf)
import Data.Maybe (maybeToList, isJust, isNothing)
import Prelude

import Options.Applicative.Internal
import Options.Applicative.Types

showOption :: OptName -> String
showOption (OptLong n) = "--" ++ n
showOption (OptShort n) = '-' : [n]

optionNames :: OptReader a -> [OptName]
optionNames (OptReader names _ _) = names
optionNames (FlagReader names _) = names
optionNames _ = []

isOptionPrefix :: OptName -> OptName -> Bool
isOptionPrefix (OptShort x) (OptShort y) = x == y
isOptionPrefix (OptLong x) (OptLong y) = x `isPrefixOf` y
isOptionPrefix _ _ = False

-- | Create a parser composed of a single option.
liftOpt :: Option a -> Parser a
liftOpt = OptP

argMatches :: MonadP m => OptReader a -> String
           -> Maybe (StateT Args m a)
argMatches opt arg = case opt of
  ArgReader rdr -> Just . lift $
    runReadM (crReader rdr) arg
  CmdReader _ _ f ->
    flip fmap (f arg) $ \subp -> StateT $ \args -> do
      prefs <- getPrefs
      let runSubparser
            | prefBacktrack prefs = \i a ->
                runParser (infoPolicy i) CmdStart (infoParser i) a
            | otherwise = \i a
            -> (,) <$> runParserInfo i a <*> pure []
      enterContext arg subp *> runSubparser subp args <* exitContext
  _ -> Nothing

optMatches :: MonadP m => Bool -> OptReader a -> OptWord -> Maybe (StateT Args m a)
optMatches disambiguate opt (OptWord arg1 val) = case opt of
  OptReader names rdr no_arg_err -> do
    guard $ has_name arg1 names
    Just $ do
      args <- get
      let mb_args = uncons $ maybeToList val ++ args
      let missing_arg = missingArgP (no_arg_err $ showOption arg1) (crCompleter rdr)
      (arg', args') <- maybe (lift missing_arg) return mb_args
      put args'
      lift $ runReadM (withReadM (errorFor arg1) (crReader rdr)) arg'

  FlagReader names x -> do
    guard $ has_name arg1 names
    -- #242 Flags/switches succeed incorrectly when given an argument.
    -- We'll not match a long option for a flag if there's a word attached.
    -- This was revealing an implementation detail as
    -- `--foo=val` was being parsed as `--foo -val`, which is gibberish.
    guard $ is_short arg1 || isNothing val
    Just $ do
      args <- get
      let val' = (\s -> '-' : s) <$> val
      put $ maybeToList val' ++ args
      return x
  _ -> Nothing
  where
    errorFor name msg = "option " ++ showOption name ++ ": " ++ msg

    is_short (OptShort _) = True
    is_short (OptLong _)  = False

    has_name a
      | disambiguate = any (isOptionPrefix a)
      | otherwise = elem a

isArg :: OptReader a -> Bool
isArg (ArgReader _) = True
isArg _ = False

data OptWord = OptWord OptName (Maybe String)

parseWord :: String -> Maybe OptWord
parseWord ('-' : '-' : w) = Just $ let
  (opt, arg) = case span (/= '=') w of
    (_, "") -> (w, Nothing)
    (w', _ : rest) -> (w', Just rest)
  in OptWord (OptLong opt) arg
parseWord ('-' : w) = case w of
  [] -> Nothing
  (a : rest) -> Just $ let
    arg = rest <$ guard (not (null rest))
    in OptWord (OptShort a) arg
parseWord _ = Nothing

searchParser :: Monad m
             => (forall r . Option r -> NondetT m r)
             -> Parser a -> NondetT m (Parser a)
searchParser _ (NilP _) = mzero
searchParser f (OptP opt) = liftM pure (f opt)
searchParser f (MultP p1 p2) = foldr1 (<!>)
  [ do p1' <- searchParser f p1
       return (p1' <*> p2)
  , do p2' <- searchParser f p2
       return (p1 <*> p2') ]
searchParser f (AltP p1 p2) = msum
  [ searchParser f p1
  , searchParser f p2 ]
searchParser f (BindP p k) = msum
  [ do p' <- searchParser f p
       return $ BindP p' k
  , case evalParser p of
      Nothing -> mzero
      Just aa -> searchParser f (k aa) ]

searchOpt :: MonadP m => ParserPrefs -> OptWord -> Parser a
          -> NondetT (StateT Args m) (Parser a)
searchOpt pprefs w = searchParser $ \opt -> do
  let disambiguate = prefDisambiguate pprefs
                  && optVisibility opt > Internal
  case optMatches disambiguate (optMain opt) w of
    Just matcher -> lift matcher
    Nothing -> mzero

searchArg :: MonadP m => String -> Parser a
          -> NondetT (StateT Args m) (Parser a)
searchArg arg = searchParser $ \opt -> do
  when (isArg (optMain opt)) cut
  case argMatches (optMain opt) arg of
    Just matcher -> lift matcher
    Nothing -> mzero

stepParser :: MonadP m => ParserPrefs -> ArgPolicy -> String
           -> Parser a -> NondetT (StateT Args m) (Parser a)
stepParser _ AllPositionals arg p =
  searchArg arg p
stepParser pprefs ForwardOptions arg p = case parseWord arg of
  Just w -> searchOpt pprefs w p <|> searchArg arg p
  Nothing -> searchArg arg p
stepParser pprefs _ arg p = case parseWord arg of
  Just w -> searchOpt pprefs w p
  Nothing -> searchArg arg p


-- | Apply a 'Parser' to a command line, and return a result and leftover
-- arguments.  This function returns an error if any parsing error occurs, or
-- if any options are missing and don't have a default value.
runParser :: MonadP m => ArgPolicy -> IsCmdStart -> Parser a -> Args -> m (a, Args)
runParser policy _ p ("--" : argt) | policy /= AllPositionals
                                   = runParser AllPositionals CmdCont p argt
runParser policy isCmdStart p args = case args of
  [] -> exitP isCmdStart policy p result
  (arg : argt) -> do
    prefs <- getPrefs
    (mp', args') <- do_step prefs arg argt
    case mp' of
      Nothing -> hoistMaybe result <|> parseError arg p
      Just p' -> runParser (newPolicy arg) CmdCont p' args'
  where
    result = (,) <$> evalParser p <*> pure args
    do_step prefs arg argt = (`runStateT` argt)
                           . disamb (not (prefDisambiguate prefs))
                           $ stepParser prefs policy arg p

    newPolicy a = case policy of
      NoIntersperse -> if isJust (parseWord a) then NoIntersperse else AllPositionals
      x             -> x

parseError :: MonadP m => String -> Parser x -> m a
parseError arg = errorP . UnexpectedError arg . SomeParser

runParserInfo :: MonadP m => ParserInfo a -> Args -> m a
runParserInfo i = runParserFully (infoPolicy i) (infoParser i)

runParserFully :: MonadP m => ArgPolicy -> Parser a -> Args -> m a
runParserFully policy p args = do
  (r, args') <- runParser policy CmdStart p args
  case args' of
    []  -> return r
    a:_ -> parseError a (pure ())

-- | The default value of a 'Parser'.  This function returns an error if any of
-- the options don't have a default value.
evalParser :: Parser a -> Maybe a
evalParser (NilP r) = r
evalParser (OptP _) = Nothing
evalParser (MultP p1 p2) = evalParser p1 <*> evalParser p2
evalParser (AltP p1 p2) = evalParser p1 <|> evalParser p2
evalParser (BindP p k) = evalParser p >>= evalParser . k

-- | Map a polymorphic function over all the options of a parser, and collect
-- the results in a list.
mapParser :: (forall x. OptHelpInfo -> Option x -> b)
          -> Parser a -> [b]
mapParser f = flatten . treeMapParser f
  where
    flatten (Leaf x) = [x]
    flatten (MultNode xs) = xs >>= flatten
    flatten (AltNode xs) = xs >>= flatten

-- | Like 'mapParser', but collect the results in a tree structure.
treeMapParser :: (forall x . OptHelpInfo -> Option x -> b)
          -> Parser a
          -> OptTree b
treeMapParser g = simplify . go False False False g
  where
    has_default :: Parser a -> Bool
    has_default p = isJust (evalParser p)

    go :: Bool -> Bool -> Bool
       -> (forall x . OptHelpInfo -> Option x -> b)
       -> Parser a
       -> OptTree b
    go _ _ _ _ (NilP _) = MultNode []
    go m d r f (OptP opt)
      | optVisibility opt > Internal
      = Leaf (f (OptHelpInfo m d r) opt)
      | otherwise
      = MultNode []
    go m d r f (MultP p1 p2) = MultNode [go m d r f p1, go m d r' f p2]
      where r' = r || has_positional p1
    go m d r f (AltP p1 p2) = AltNode [go m d' r f p1, go m d' r f p2]
      where d' = d || has_default p1 || has_default p2
    go _ d r f (BindP p k) =
      let go' = go True d r f p
      in case evalParser p of
        Nothing -> go'
        Just aa -> MultNode [ go', go True d r f (k aa) ]

    has_positional :: Parser a -> Bool
    has_positional (NilP _) = False
    has_positional (OptP p) = (is_positional . optMain) p
    has_positional (MultP p1 p2) = has_positional p1 || has_positional p2
    has_positional (AltP p1 p2) = has_positional p1 || has_positional p2
    has_positional (BindP p _) = has_positional p

    is_positional :: OptReader a -> Bool
    is_positional (OptReader {})  = False
    is_positional (FlagReader {}) = False
    is_positional (ArgReader {})  = True
    is_positional (CmdReader {})  = True


simplify :: OptTree a -> OptTree a
simplify (Leaf x) = Leaf x
simplify (MultNode xs) =
  case concatMap (remove_mult . simplify) xs of
    [x] -> x
    xs' -> MultNode xs'
  where
    remove_mult (MultNode ts) = ts
    remove_mult t = [t]
simplify (AltNode xs) =
  case concatMap (remove_alt . simplify) xs of
    []  -> MultNode []
    [x] -> x
    xs' -> AltNode xs'
  where
    remove_alt (AltNode ts) = ts
    remove_alt (MultNode []) = []
    remove_alt t = [t]
