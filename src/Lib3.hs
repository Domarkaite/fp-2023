{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use <$>" #-}
{-# OPTIONS_GHC -Wno-unused-do-bind #-}

module Lib3
  ( executeSql,
    parseStatement,
    Execution,
    ParsedStatement2,
    ExecutionAlgebra(..)
  )
where
import Lib2
import Lib1 (renderDataFrameAsTable, findTableByName, parseSelectAllStatement, checkTupleMatch, zipColumnsAndValues, checkRowSizes)
import Control.Monad.Free (Free (..), liftF)
import DataFrame
import Data.Time
import Data.Either (fromRight)
import Text.ParserCombinators.ReadP (many1)
import GHC.Generics
import Data.Aeson hiding (Value)
import GHC.Generics
import DataFrame
import GHC.Base (VecElem(DoubleElemRep))
import Debug.Trace (trace, traceShow)
import Data.Char (isDigit)

type TableName = String
type FileContent = String
type DeserializedContent = (TableName, DataFrame)
type ErrorMessage = String
type TableArray =  [TableName]

data ExecutionAlgebra next
  = LoadFile TableName (FileContent -> next)
  | GetTime (UTCTime -> next)
  -- feel free to add more constructors heres
  deriving Functor

type Execution = Free ExecutionAlgebra

data FromJSONColumn = FromJSONColumn {
    deserializedName :: String,
    deserializedDataType :: String
} deriving (Show, Eq, Generic)

data FromJSONTable = FromJSONTable {
    deserializedtableName :: String,
    deserializedColumns :: [FromJSONColumn],
    deserializedRows :: [[Value]]
} deriving (Show, Eq, Generic)



-- instance FromJSON FromJSONColumn where
--   parseJSON (Object v) =
--     FromJSONColumn <$> v .: "name"
--                    <*> V .: "columnType"
--   parseJSON _ = mzero

-- instance FromJSON FromJSONTable where
--   parseJSON (Object v) =
--     FromJSONTable <$> v .: "table"
--                   <*> FromJSONColumn .: "columns"
--                   <*> FromJSONRows .: "Rows"
--   parseJSON _ = mzero

--instance FromJSON FromJSONTable

-- Keep the type, modify constructors
data ParsedStatement2 =
  SelectNow {}
  | Insert {
    table :: TableName,
    columns :: Maybe SelectedColumns,
    values :: InsertedValues
  }
  | Update {
    table :: TableName,
    selectUpdate :: Maybe WhereSelect,
    selectWhere :: Maybe WhereSelect
  }
  | Delete {
    table :: TableName,
    conditions :: Maybe WhereSelect
  }
  | ShowTable {
    table :: TableName
   }
  |SelectAll {
    tables :: TableArray,
    selectWhere :: Maybe WhereSelect
   }
  |Select {
    selectQuery :: SpecialSelect,
    tables :: TableArray,
    selectWhere :: Maybe WhereSelect
  }
  | ShowTables { }
    deriving (Show, Eq)

data SelectedColumns = ColumnsSelected [ColumnName]
  deriving (Show, Eq)

type InsertedValues = [Value]

loadFile :: TableName -> Execution FileContent
loadFile name = liftF $ LoadFile name id

getTime :: Execution UTCTime
getTime = liftF $ GetTime id

executeSql :: String -> Execution (Either ErrorMessage DataFrame)
executeSql sql = case parseStatement2 sql of
  Left err -> return $ Left err
  Right (ShowTable table) -> do
    content <- loadFile table
    return $ Left content
  Right (Insert table columns values) -> do
    content <- loadFile table
    case content of
            Left err1 -> return $ Left err1
            Right contains -> do
              let df = insertExecution contains columns values
              return $ Right df
  Right (Update table selectUpdate selectWhere) -> do
    return $ Left "wowoo"
  Right (Delete table conditions) -> do
    return $ Left "wowoo"
  Right SelectNow -> do
    da <- getTime
    let df = createNowDataFrame (uTCToString da)
    return $ Right df

insertExecution :: DeserializedContent -> Maybe SelectedColumns -> InsertedValues -> Either ErrorMessage DataFrame
insertExecution contains columns values = --DataFrame [Column "Now" StringType] [[IntegerValue 1, StringValue "babe"]]
  case columns of 
    Just columnsFound -> insertColumnsProvided contains columnsFound values
    Nothing -> insertToAll contains values


insertColumnsProvided :: DeserializedContent -> SelectedColumns -> InsertedValues -> Either ErrorMessage DataFrame
insertColumnsProvided content columns values = DataFrame [Column "Now" StringType] [[IntegerValue 1, StringValue "babe"]]

insertToAll :: DeserializedContent -> InsertedValues -> Either ErrorMessage DataFrame
insertToAll content values = DataFrame [Column "Now" StringType] [[IntegerValue 1, StringValue "babe"]]

--deserializeTable :: FileContent -> Either ErrorMessage DeserializedContent


createNowDataFrame :: [Row] -> DataFrame
createNowDataFrame time = DataFrame [Column "Now" StringType] time

uTCToString :: UTCTime -> [Row]
uTCToString utcTime = [[StringValue (formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" utcTime)]]
-------------------------------some JSON shit------------------------------------

toJSONtable :: (TableName, (DataFrame)) -> String
toJSONtable table = "{\"Table\":\"" ++ show (fst (table)) ++ "\",\"Columns\":[" ++ show (toJSONColumns (toColumnList (snd (table)))) ++ "],\"Rows\":[" ++ show (toJSONRows (toRowList (snd (table)))) ++"]}"

toJSONColumn :: Column -> String
toJSONColumn column = "{\"Name\":\"" ++ show (getColumnName (column)) ++ ",\"ColumnType\":\"" ++ show (getType (column)) ++ "\"}"

toJSONRowValue :: Value -> String
toJSONRowValue value = "{\"Value\":\"" ++ show (value) ++ "\"}"

---------------------------------------some get stuff----------------------------

toColumnList :: DataFrame -> [Column]
toColumnList (DataFrame col row)  = col

toRowList :: DataFrame -> [Row]
toRowList (DataFrame co row) = row

----------------------------------recursive stuff-------------------------------

toJSONColumns :: [Column] -> String
toJSONColumns (x:xs)
  |xs /= [] = toJSONColumn x ++ "," ++ toJSONColumns xs
  |otherwise = toJSONColumn x

toJSONRow :: Row -> String
--toJSONRow [] = []
toJSONRow (x:xs)
  |xs /= [] = toJSONRowValue x ++ "," ++ toJSONRow xs
  |otherwise = toJSONRowValue x

toJSONRows :: [Row] -> String
toJSONRows (x:xs)
  |xs /= [] = "[" ++ toJSONRow x ++ "]," ++ toJSONRows xs
  |otherwise = "[" ++ toJSONRow x ++ "]"

--------------------------------Files--------------------------------------------
-- --C:\Users\Gita\Documents\GitHub\fp-2023\db\flags.json
toFilePath :: TableName -> FilePath
toFilePath tableName = "db/" ++ show (tableName) ++ ".json" --".txt"

writeTableToFile :: (TableName, DataFrame) -> IO ()
writeTableToFile table = writeFile (toFilePath (fst (table))) (toJSONtable (table))

---------------------------------------------------------------------------------

parseStatement2 :: String -> Either ErrorMessage ParsedStatement2
parseStatement2 query = case runParser p query of
    Left err1 -> Left err1
    Right (query, rest) -> case query of
        Select _ _ _ -> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
        ShowTable _ -> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
        ShowTables -> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
        SelectAll _ _ -> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
        Insert _ _ _ -> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
        Update _ _ _-> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
        Delete _ _ -> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
        SelectNow -> case runParser stopParseAt rest of
          Left err2 -> Left err2
          Right _ -> Right query
    where
        p :: Parser ParsedStatement2
        p = showTableParser
               <|> showTablesParser
               <|> selectStatementParser
               <|> selectAllParser
               <|> insertParser
               <|> updateParser
               <|> deleteParser
               <|> selectNowParser

selectNowParser :: Parser ParsedStatement2
selectNowParser = do
    _ <- queryStatementParser "select"
    _ <- whitespaceParser
    _ <- queryStatementParser "now"
    _ <- optional whitespaceParser
    _ <- queryStatementParser "("
    _ <- optional whitespaceParser
    _ <- queryStatementParser ")"
    pure SelectNow

insertParser :: Parser ParsedStatement2
insertParser = do
    _ <- queryStatementParser "insert"
    _ <- whitespaceParser
    _ <- queryStatementParser "into"
    _ <- whitespaceParser
    tableName <- columnNameParser
    _ <- optional whitespaceParser
    _ <- queryStatementParser "("
    selectUpdate <- optional selectDataParsers
    _ <- queryStatementParser ")"
    _ <- optional whitespaceParser
    _ <- queryStatementParser "values"
    _ <- optional whitespaceParser
    _ <- queryStatementParser "("
    values <- insertedValuesParser
    _ <- queryStatementParser ")"
    pure $ Insert tableName selectUpdate values


insertedValuesParser :: Parser InsertedValues
insertedValuesParser = do
  values <- seperate valueParser (queryStatementParser "," >> whitespaceParser)
  return $ trace ("Parsed values: " ++ show values) values

valueParser :: Parser Value
valueParser = parseNullValue <|> parseBoolValue <|> parseStringValue <|> parseNumericValue

parseNullValue :: Parser Value
parseNullValue = queryStatementParser "null" >> return NullValue

parseBoolValue :: Parser Value
parseBoolValue =
  (queryStatementParser "true" >> return (BoolValue True))
  <|> (queryStatementParser "false" >> return (BoolValue False))

parseStringValue :: Parser Value
parseStringValue = do
  strValue <- parseStringWithQuotes
  return (StringValue strValue)

parseStringWithQuotes :: Parser String
parseStringWithQuotes = do
  _ <- queryStatementParser "'"
  str <- some (parseSatisfy (/= '\''))
  _ <- queryStatementParser "'"
  return str

parseNumericValue :: Parser Value
parseNumericValue = IntegerValue <$> parseInt

parseInt :: Parser Integer
parseInt = do
  digits <- some (parseSatisfy isDigit)
  return (read digits)

deleteParser :: Parser ParsedStatement2
deleteParser = do
    _ <- queryStatementParser "delete"
    _ <- whitespaceParser
    _ <- queryStatementParser "from"
    _ <- whitespaceParser
    tableName <- columnNameParser
    conditions <- optional whereParser
    pure $ Delete tableName conditions

updateParser :: Parser ParsedStatement2
updateParser = do
    _ <- queryStatementParser "update"
    _ <- whitespaceParser
    tableName <- columnNameParser
    _ <- whitespaceParser
    _ <- queryStatementParser "set"
    selectUpdated <- optional setParserWithComma
    selectedWhere <- optional whereParser
    pure $ Update tableName selectUpdated selectedWhere

setParserWithComma :: Parser WhereSelect
setParserWithComma = do
  _ <- whitespaceParser
  some setCommaExist

  where
    setCommaExist :: Parser Condition
    setCommaExist = do
      condition <- whereConditionParser
      _ <- optional (queryStatementParser "," >> whitespaceParser)
      pure condition

selectDataParsers :: Parser SelectedColumns
selectDataParsers = tryParseColumn
  where
    tryParseColumn = do
      columnNames <- seperate columnNameParser (optional whitespaceParser >> char ',' *> optional whitespaceParser)
      return $ ColumnsSelected columnNames

----Lib2 stuff----
selectAllParser :: Parser ParsedStatement2
selectAllParser = do
  _ <- queryStatementParser "select"
  _ <- whitespaceParser
  _ <- queryStatementParser "*"
  _ <- whitespaceParser
  _ <- queryStatementParser "from"
  _ <- whitespaceParser
  tableArray <- selectTablesParser
  selectWhere <- optional whereParser
  _ <- optional whitespaceParser
  pure $ SelectAll tableArray selectWhere

selectStatementParser :: Parser ParsedStatement2
selectStatementParser = do
    _ <- queryStatementParser "select"
    _ <- whitespaceParser
    specialSelect <- selectDataParser
    _ <- whitespaceParser
    _ <- queryStatementParser "from"
    _ <- whitespaceParser
    tableArray <- selectTablesParser
    _ <- optional whitespaceParser
    selectWhere <- optional whereParser
    _ <- optional whitespaceParser
    pure $ Select specialSelect tableArray selectWhere

selectTablesParser :: Parser TableArray
selectTablesParser = tryParseTable
  where
    tryParseTable = do
      tableNames <- seperate columnNameParser (optional whitespaceParser >> char ',' *> optional whitespaceParser)
      return $ tableNames

showTablesParser :: Parser ParsedStatement2
showTablesParser = do
    _ <- queryStatementParser "show"
    _ <- whitespaceParser
    _ <- queryStatementParser "tables"
    _ <- optional whitespaceParser
    pure ShowTables

-----------------------------------------------------------------------------------------------------------

showTableParser :: Parser ParsedStatement2
showTableParser = do
    _ <- queryStatementParser "show"
    _ <- whitespaceParser
    _ <- queryStatementParser "table"
    _ <- whitespaceParser
    table <- columnNameParser
    _ <- optional whitespaceParser
    pure $ ShowTable table
