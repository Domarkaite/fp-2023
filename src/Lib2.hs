{-# OPTIONS_GHC -Wno-unused-top-binds #-}
{-# LANGUAGE BlockArguments #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE DataKinds #-}
{-# OPTIONS_GHC -Wno-overlapping-patterns #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Eta reduce" #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# HLINT ignore "Redundant return" #-}
{-# OPTIONS_GHC -Wno-orphans #-}


module Lib2
  ( parseStatement,
    executeStatement,
    ParsedStatement (..),
    queryStatementParser,
    whitespaceParser,
    showTablesParser,
    showTableParser,
    tableNameParser,
    isValidTableName,
    isOneWord,
    dropWhiteSpaces,
    columnsToList,
    getColumnName,
    findTableNames,
    findTuples,
    firstFromTuple,
    selectStatementParser,
    --columnNamesParser,
    areColumnsListedRight,
    splitStatementAtFrom,
    split,
    toLowerString,
    charToString,
    createColumnsDataFrame,
    createSelectDataFrame,
    createTablesDataFrame,
    stopParseAt
  )
where

import DataFrame
    ( DataFrame(..),
      Row,
      Column(..),
      ColumnType(..),
      Value(..),
      DataFrame)
import InMemoryTables (TableName, database)
import Data.List.NonEmpty (some1, xor)
import Foreign.C (charIsRepresentable)
import Data.Char (toLower, GeneralCategory (ParagraphSeparator), isSpace, isAlphaNum)
import qualified InMemoryTables as DataFrame
import Lib1 (renderDataFrameAsTable, findTableByName)
import Data.List (isPrefixOf, nub)
import Data.Maybe (fromMaybe)
import Data.Either
import Text.ParserCombinators.ReadP (get)
import Data.Foldable (find)
import Data.Monoid (All)
import GHC.Windows (errCodeToIOError)

type ErrorMessage = String
type Database = [(TableName, DataFrame)]

type ColumnName = String

type Aggregate = (AggregateFunction, ColumnName)

data AggregateFunction = Sum | Max
  deriving (Show, Eq)

data SpecialSelect = SelectAggregate AggregateList | SelectColumns [ColumnName]
  deriving (Show, Eq)

type AggregateList = [(AggregateFunction, ColumnName)]

-- Keep the type, modify constructors
data ParsedStatement =
  Select {
    selectQuery :: SpecialSelect, 
    table :: TableName
  }
  | ShowTable {
    table :: TableName
   }
  | ShowTables { }
    deriving (Show, Eq)

--------------------------------------------------------------------------------
newtype Parser a = Parser {
    runParser :: String -> Either ErrorMessage (a, String)
}

instance Functor Parser where
  fmap f (Parser x) = Parser $ \s -> do
    (x', s') <- x s
    return (f x', s')

instance Applicative Parser where
  pure x = Parser $ \s -> Right (x, s)
  (Parser f) <*> (Parser x) = Parser $ \s -> do
    (f', s1) <- f s
    (x', s2) <- x s1
    return (f' x', s2)

instance Monad Parser where
  (Parser x) >>= f = Parser $ \s -> do
    (x', s') <- x s
    runParser (f x') s'

instance MonadFail Parser where
  fail _ = Parser $ \_ -> Left "Monad failed"

class (Applicative f) => Alternative f where
  empty :: f a
  ( <|> ) :: f a -> f a -> f a
  some :: f a -> f [a]
  some v = some_v
    where many_v = some_v <|> pure []
          some_v = (:) <$> v <*> many_v

  many :: f a -> f [a]
  many v = many_v
    where many_v = some_v <|> pure []
          some_v = (:) <$> v <*> many_v

instance Alternative Parser where
  empty = fail "empty"
  (Parser x) <|> (Parser y) = Parser $ \s ->
    case x s of
      Right x -> Right x
      Left _ -> y s

char :: Char -> Parser Char
char c = Parser charP
  where charP []                 = Left "Empty input"
        charP (x:xs) | x == c    = Right (c, xs)
                     | otherwise = Left ("Expected " ++ [c])


optional :: Parser a -> Parser (Maybe a)
optional p = do
  result <- p
  return (Just result)
  <|> return Nothing

----------------------------------------------------------------------------------

parseStatement :: String -> Either ErrorMessage ParsedStatement
parseStatement query = case runParser p query of
    Left err1 -> Left err1
    Right (query, rest) -> case query of
        ShowTables -> case runParser stopParseAt rest of
            Left err2 -> Left err2
            Right _ -> Right query
        ShowTable _ -> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
        Select _ _ -> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
    where
        p :: Parser ParsedStatement
        p = showTablesParser
               <|> showTableParser
               <|> selectStatementParser


executeStatement :: ParsedStatement -> Either ErrorMessage DataFrame
executeStatement ShowTables = Right $ createTablesDataFrame findTableNames
executeStatement (ShowTable table) = Right (createColumnsDataFrame (columnsToList (fromMaybe (DataFrame [] []) (lookup table InMemoryTables.database))) table)
executeStatement (Select selectQuery table) =
  case selectQuery of 
  SelectColumns cols -> do 
    case doColumnsExist cols (fromMaybe (DataFrame [] []) (lookup table InMemoryTables.database)) of 
      True -> Right (createSelectDataFrame
                    (fst (getColumnsRows cols (fromMaybe (DataFrame [] []) (lookup table InMemoryTables.database))))
                    (snd (getColumnsRows cols (fromMaybe (DataFrame [] []) (lookup table InMemoryTables.database))))
                    )
      False -> Left "Provided column name does not exist in database"
  SelectAggregate aggList -> do
    case processSelect table aggList of
      Left err -> Left err
      Right (newCols, newRows) -> Right $ createSelectDataFrame newCols newRows

  -- SelectAggregate (Aggregate aggF colN) -> do
executeStatement _ = Left "Not implemented: executeStatement for other statements"  

---------------------------------------------------------------------------------
--where tures buti cia
processSelect :: TableName -> AggregateList -> Either ErrorMessage ([Column],[Row])
processSelect table aggList =
  case (doColumnsExist (getColumnNames aggList) (fromMaybe (DataFrame [] []) (lookup table InMemoryTables.database))) of 
    False -> Left "Some of the provided columns do not exist" 
    True -> case validateDataFrame (fromMaybe (DataFrame [] []) (lookup table InMemoryTables.database)) of
      False -> Left "Selected table is not valid"
      True -> case (processSelectAggregates (fromMaybe (DataFrame [] []) (lookup table InMemoryTables.database)) aggList) of
        Left err -> Left err
        Right [(clm, vl)] -> Right (fst $ switchListToTuple [(clm, vl)], [snd $ switchListToTuple [(clm, vl)]])


processSelectAggregates :: DataFrame -> [(AggregateFunction, ColumnName)] -> Either ErrorMessage [(Column, Value)] -- -> ([Column], [Value])
processSelectAggregates _ [] = Right []
processSelectAggregates (DataFrame cols rows) ((func, colName):xs) =
  case func of
     Max ->  --Right ([((Column ("Max from " ++ colName) (head (getColumnType [colName] cols))), 
    --               (findMax (snd (getColumnsRows [colName] (DataFrame cols rows)))))] 
    --               ++ (fromRight [] ( processSelectAggregates (DataFrame cols rows) xs)))
      Left "blabla"


    --( [(Column ("Max from " ++ colName) (getColumnType [colName] cols))] ++ fst $ processSelectAggregates (DataFrame cols rows) xs,
    --                [(findMax (snd (getColumnsRows [colName] (fromMaybe (DataFrame [] []) (lookup table InMemoryTables.database)))))] ++ snd $ processSelectAggregates (DataFrame cols rows) xs)
    --Sum -> reiks err message

getColumnNames :: [(AggregateFunction, ColumnName)] -> [ColumnName]
getColumnNames aggregates = nub [col | (_, col) <- aggregates]

switchListToTuple :: [(Column, Value)] -> ([Column], [Value])
switchListToTuple [] = ([], []) -- Base case for an empty list
switchListToTuple ((col, val):rest) =
    let (cols, vals) = switchListToTuple rest
    in (col : cols, val : vals)

instance Ord Value where
    compare val1 val2 
        | val1 <= val2 || val2 <= val1 = EQ
        | val1 < val2 = LT
        | otherwise = GT

findMax :: [Row] -> Value -- listas normalus, listas is 1 elemento
findMax row = head (maximum row)

-- rowToRowList :: Row -> [Row]
-- rowToRowList row = [row]

---------------------------------------------------------------------------------
-- might need to delete later (check only after everything is done)

validateDataFrame :: DataFrame -> Bool
validateDataFrame dataFrame
  | not (checkRowSizes dataFrame) = False
  | not (checkTupleMatch (zipColumnsAndValues dataFrame)) = False
  | otherwise = True

checkTupleMatch :: [(Column, Value)] -> Bool
checkTupleMatch [] = True  -- Base case when the list is empty
checkTupleMatch ((column, value) : rest) =
   case (column, value) of
    (Column _ IntegerType, IntegerValue _) -> checkTupleMatch rest
    (Column _ StringType, StringValue _) -> checkTupleMatch rest
    (Column _ BoolType, BoolValue _) -> checkTupleMatch rest
    _ -> False  -- Match any other case

zipColumnsAndValues :: DataFrame -> [(Column, Value)]
zipColumnsAndValues (DataFrame columns rows) = [(col, val) | row <- rows, (col, val) <- zip columns row]

checkRowSizes :: DataFrame -> Bool
checkRowSizes (DataFrame columns rows) = all (\row -> length row == length columns) rows

---------------------------------------------------------------------------------

queryStatementParser :: String -> Parser String
queryStatementParser queryStatement = Parser $ \query ->
    case take (length queryStatement) query of
        [] -> Left "Expected ;"
        xs
            | map toLower xs == map toLower queryStatement -> Right (xs, drop (length xs) query)
            | otherwise -> Left $ "Expected " ++ queryStatement ++ " or query contains unnecessary words"

whitespaceParser :: Parser String
whitespaceParser = Parser $ \query ->
    case span isSpace query of
        ("", _) -> Left $ "Expected whitespace before " ++  query
        (rest, whitespace) -> Right (rest, whitespace)

-------------------------------------------------------------------------------------

showTablesParser :: Parser ParsedStatement
showTablesParser = do
    _ <- queryStatementParser "show"
    _ <- whitespaceParser
    _ <- queryStatementParser "tables"
    _ <- optional whitespaceParser
    pure ShowTables

------------------------------------------------------------------------------------

showTableParser :: Parser ParsedStatement
showTableParser = do
    _ <- queryStatementParser "show"
    _ <- whitespaceParser
    _ <- queryStatementParser "table"
    _ <- optional whitespaceParser
    ShowTable <$> tableNameParser

tableNameParser :: Parser TableName
tableNameParser = Parser $ \query ->
  case isValidTableName query of
    True ->
      case lookup (dropWhiteSpaces (init query)) InMemoryTables.database of
      Just _ -> Right (init (dropWhiteSpaces query), ";")
      Nothing -> Left "Table not found in the database or not provided"
    False -> Left "Query does not end with ; or contains unnecessary words after table name"

isValidTableName :: String -> Bool
isValidTableName str
  | dropWhiteSpaces str == "" = False
  | last str == ';' = isOneWord (init str)
  | otherwise = False

isOneWord :: String -> Bool
isOneWord [] = True
isOneWord (x:xs)
  | x /= ' ' = isOneWord xs
  | x == ' ' = dropWhiteSpaces xs == ";"

dropWhiteSpaces :: String -> String
dropWhiteSpaces [] = []
dropWhiteSpaces (x:xs)
  | x /= ' ' = [x] ++ dropWhiteSpaces xs
  | otherwise = dropWhiteSpaces xs

columnsToList :: DataFrame -> [ColumnName]
columnsToList (DataFrame [] []) = []
columnsToList (DataFrame columns _) = map getColumnName columns

getColumnName :: Column -> ColumnName
getColumnName (Column "" _) = ""
getColumnName (Column columnname _) = columnname

findTableNames :: [ColumnName]
findTableNames = findTuples InMemoryTables.database

findTuples :: Database -> [ColumnName]
findTuples [] = []
findTuples db = map firstFromTuple db

firstFromTuple :: (ColumnName, DataFrame) -> ColumnName
firstFromTuple = fst

-----------------------------------------------------------------------------------------------------------

selectStatementParser :: Parser ParsedStatement
selectStatementParser = do
    _ <- queryStatementParser "select"
    _ <- optional whitespaceParser
    specialSelect <- selectDataParser
    _ <- whitespaceParser
    _ <- queryStatementParser "from"
    _ <- whitespaceParser
    Select specialSelect <$> tableNameParser

selectDataParser :: Parser SpecialSelect
selectDataParser = tryParseAggregate <|> tryParseColumn
  where
    tryParseAggregate = do
      aggregateList <- aggregateParser `sepBy` (char ',' *> optional whitespaceParser)
      return $ SelectAggregate aggregateList
    tryParseColumn = do
      columnNames <- optional whitespaceParser *> columnNameParser `sepBy` (char ',' *> optional whitespaceParser)
      return $ SelectColumns columnNames

aggregateParser :: Parser Aggregate
aggregateParser = do
    func <- aggregateFunctionParser
    _ <- optional whitespaceParser
    _ <- char '('
    _ <- optional whitespaceParser
    columnName <- columnNameParser'
    _ <- optional whitespaceParser
    _ <- char ')'
    pure (func, columnName)

aggregateFunctionParser :: Parser AggregateFunction
aggregateFunctionParser = sumParser <|> maxParser 
  where
    sumParser = do
        _ <- queryStatementParser "sum"
        pure Sum
    maxParser = do
        _ <- queryStatementParser "max"
        pure Max

columnNameParser :: Parser ColumnName
columnNameParser = Parser $ \inp ->
    case takeWhile (\x -> isAlphaNum x || x == '_') inp of
        [] -> Left "Empty input"
        xs -> Right (drop (length xs) inp, xs)

sepBy :: Parser a -> Parser b -> Parser [a]
sepBy p sep = do
    x <- p
    xs <- many (sep *> p)
    return (x:xs)


getAggregateList :: [String] -> Either ErrorMessage [(AggregateFunction, ColumnName)]
getAggregateList [] = Right []
getAggregateList (x:xs)
  | "max(" `isPrefixOf` dropWhiteSpaces x && last (dropWhiteSpaces x) == ')' = Right ([(Max, init (drop 4 (dropWhiteSpaces x)))] ++ (fromRight [] $ getAggregateList xs))
  | "sum(" `isPrefixOf` dropWhiteSpaces x && last (dropWhiteSpaces x) == ')' = Right ([(Sum, init (drop 4 (dropWhiteSpaces x)))] ++ (fromRight [] $ getAggregateList xs))
  | otherwise = Left "Incorrect syntax of aggregate functions"

columnNameParser' :: Parser ColumnName
columnNameParser' = Parser $ \query ->  
  -- case isOneWord' query of
  --   True -> 
  case isSpacesBetweenWords (fst (splitStatementAtParentheses query)) of
      True -> Right (dropWhiteSpaces (fst (splitStatementAtParentheses query)), snd (splitStatementAtParentheses query))
      False -> Left "There is more than one column name in aggregation function"
    -- False -> Left ("There is more than one column name in aggregation function or ')' is missing")

-- isOneWord' :: String -> Bool
-- isOneWord' [] = True
-- isOneWord' (x:xs)
--   | x == ',' = False
--   | x == ' ' = isOneWord' xs
--   | x == ')' = True
--   | otherwise = isOneWord' xs

isSpacesBetweenWords :: String -> Bool
isSpacesBetweenWords [] = True
isSpacesBetweenWords (x:xs)
  | x == ' ' = dropWhiteSpacesUntilName xs == ""
  | otherwise = isSpacesBetweenWords xs

splitStatementAtParentheses :: String -> (String, String)
splitStatementAtParentheses = go [] where
  go _ [] = ("", "")
  go prefix str@(x:xs)
    | ")" `isPrefixOf` toLowerString str = (reverse prefix, str)
    | otherwise = go (x:prefix) xs

-- columnNamesParser :: Parser [ColumnName]
-- columnNamesParser = Parser $ \query ->
--   case query == "" || (dropWhiteSpaces query) == ";" of
--     True -> Left "Column name is expected"
--     False -> case toLowerString (head (split query ' ')) == "from" of
--       True -> Left "No column name was provided"
--       False -> case commaBetweenColumsNames (fst (splitStatementAtFrom query)) &&  (fst (splitStatementAtFrom query)) && areColumnsListedRight (snd (splitStatementAtFrom query)) of
--         True -> Right ((split (dropWhiteSpaces (fst (splitStatementAtFrom query))) ','), snd (splitStatementAtFrom query))
--         False -> Left "Column names are not listed right or from is missing"

areColumnsListedRight :: String -> Bool
areColumnsListedRight str
  | str == "" = False
  | last (dropWhiteSpaces str) == ','  || head (dropWhiteSpaces str) == ',' =  False
  | otherwise = True

doColumnsExist :: [ColumnName] -> DataFrame -> Bool
doColumnsExist [] _ = True
doColumnsExist (x:xs) df =
    let dfColumnNames = columnsToList df
    in
      if x `elem` dfColumnNames
      then doColumnsExist xs df
      else False

splitStatementAtFrom :: String -> (String, String)
splitStatementAtFrom = go [] where
  go _ [] = ("", "")
  go prefix str@(x:xs)
    | " from" `isPrefixOf` toLowerString str = (reverse prefix, str)
    | otherwise = go (x:prefix) xs

split :: String -> Char -> [String]
split [] _ = [""]
split (c:cs) delim
    | c == delim = "" : rest
    | otherwise = (c : head rest) : tail rest
    where
        rest = split cs delim

commaBetweenColumsNames :: String -> Bool
commaBetweenColumsNames [] = True
commaBetweenColumsNames (x:xs)
  | x /= ',' && xs == "" = True
commaBetweenColumsNames (x:y:xs)
  | x == ' ' && y /=  ' ' && xs == "" = False
  | x /= ',' && y == ' ' && xs == "" = True
  | x /= ',' && xs == "" = True
  | x == ' ' && xs == "" = True
  | x == ',' && y == ' ' && xs == "" = False
  | x == ',' && y /= ' ' && xs == "" = True
  | x /= ' ' && x /= ',' = commaBetweenColumsNames (y:xs)
  | x == ',' && y /= ' ' && y /= ',' = commaBetweenColumsNames (y:xs)
  | x == ',' && whitespaceBeforeNameAfterCommaExist (y:xs) = commaBetweenColumsNames (dropWhiteSpacesUntilName (y:xs))
  | x == ' ' && commaAfterWhitespaceExist (y:xs) = commaBetweenColumsNames (y:xs)
  |otherwise = False

dropWhiteSpacesUntilName :: String -> String
dropWhiteSpacesUntilName [] = []
dropWhiteSpacesUntilName (x:xs)
  | x == ' ' = dropWhiteSpacesUntilName xs
  | otherwise = xs

whitespaceBeforeNameAfterCommaExist :: String -> Bool
whitespaceBeforeNameAfterCommaExist [] = False
whitespaceBeforeNameAfterCommaExist (x:y:xs)
  | x == ' ' && xs == "" = True
  | x /= ' ' && xs == "" = False
  | x == ' ' && y /= ' ' && y /= ',' = True
  | x == ' ' = whitespaceBeforeNameAfterCommaExist (y:xs)
  | otherwise = False

commaAfterWhitespaceExist :: String -> Bool
commaAfterWhitespaceExist [] = True
commaAfterWhitespaceExist (x:xs)
  | x == ' ' = commaAfterWhitespaceExist xs
  | x == ',' = True
  | otherwise = False

getColumnsRows :: [ColumnName] -> DataFrame -> ([Column], [Row])
getColumnsRows colList (DataFrame col row) = (getColumnList colList (getColumnType colList col) , getNewRows col row colList)

getNewRows :: [Column] -> [Row] -> [ColumnName] -> [Row]
getNewRows _ [] _ = []
getNewRows cols (x:xs) colNames = getNewRow x cols colNames : getNewRows cols xs colNames

getNewRow :: [Value] -> [Column] -> [ColumnName] -> [Value]
getNewRow _ _ [] = []
getNewRow row cols (x:xs) = getValueFromRow row (findColumnIndex x cols) 0 : getNewRow row cols xs

getValueFromRow :: Row -> Int -> Int -> Value
getValueFromRow (x:xs) index i
  | index == i = x
  | otherwise = getValueFromRow xs index (i+1)

---------------------------------------------------------------------------------------------
getColumnType :: [ColumnName] -> [Column] -> [ColumnType]
getColumnType [] _ = []
getColumnType (x:xs) col = columnType col 0 (findColumnIndex x col) : getColumnType xs col

columnType :: [Column] -> Int -> Int -> ColumnType
columnType (x:xs) i colIndex
  | i == colIndex = getType x
  | otherwise = columnType xs (i+1) colIndex

getType :: Column -> ColumnType
getType (Column _ colType) = colType

getColumnList :: [ColumnName] -> [ColumnType] -> [Column]
getColumnList [] [] = []
getColumnList (x:xs) (y:ys) = [(Column x y)] ++ getColumnList xs ys

findColumnIndex :: ColumnName -> [Column] -> Int
findColumnIndex columnName columns = columnIndex columnName columns 0

columnIndex :: ColumnName -> [Column] -> Int -> Int
columnIndex columnName ((Column name _):xs) index
    | columnName /= name = columnIndex columnName xs (index + 1)
    | otherwise = index

---------------------------------------------------------------------------------------------------------------

toLowerString :: String -> String
toLowerString [] = ""
toLowerString (x:xs) = charToString (toLower x) ++ toLowerString xs

charToString :: Char -> String
charToString c = [c]

----------------------------------------------------------------------------------------------------------

createColumnsDataFrame :: [ColumnName] -> TableName -> DataFrame
createColumnsDataFrame columnNames columnTableName = DataFrame [Column columnTableName StringType] (map (\name ->  [StringValue name]) columnNames)

createSelectDataFrame :: [Column] -> [Row] -> DataFrame
createSelectDataFrame columns rows = DataFrame columns rows

createTablesDataFrame :: [TableName] -> DataFrame
createTablesDataFrame tableNames = DataFrame [Column "Tables" StringType] (map (\name -> [StringValue name]) tableNames)

---------------------------------------------------------------------------------------------------------

stopParseAt :: Parser String
stopParseAt  = do
     _ <- optional whitespaceParser
     _ <- queryStatementParser ";"
     checkAfterQuery
     where
        checkAfterQuery :: Parser String
        checkAfterQuery = Parser $ \query ->
            case query of
                [] -> Right ([], [])
                s -> Left ("Characters found after ;" ++ s)
