module Json.Decode.Extra
    exposing
        ( (|:)
        , andMap
        , collection
        , combine
        , date
        , dict2
        , doubleEncoded
        , fromResult
        , indexedList
        , optionalField
        , parseFloat
        , parseInt
        , sequence
        , set
        , withDefault
        )

{-| Convenience functions for working with Json

Examples assume the following imports:

    import Json.Decode exposing (..)
    import Date
    import Set
    import Dict


# Date

@docs date


# Incremental Decoding

@docs andMap, (|:)


# List

@docs collection, sequence, combine, indexedList, keys


# Set

@docs set


# Dict

@docs dict2


# Maybe

@docs withDefault, optionalField


# Result

@docs fromResult


# Encoded strings

@docs parseInt, parseFloat, doubleEncoded

-}

import Date
import Dict exposing (Dict)
import Json.Decode exposing (..)
import Set exposing (Set)
import String


{-| Can be helpful when decoding large objects incrementally.

See [the `andMap` docs](https://github.com/elm-community/json-extra/blob/2.0.0/docs/andMap.md)
for an explanation of how `andMap` works and how to use it.

-}
andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap =
    map2 (|>)


{-| Infix version of `andMap` that makes for a nice DSL when decoding objects.

See [the `(|:)` docs](https://github.com/elm-community/json-extra/blob/2.0.0/docs/infixAndMap.md)
for an explanation of how `(|:)` works and how to use it.

-}
(|:) : Decoder (a -> b) -> Decoder a -> Decoder b
(|:) =
    flip andMap


{-| Extract a date using [`Date.fromString`](http://package.elm-lang.org/packages/elm-lang/core/latest/Date#fromString)

    """ "2012-04-23T18:25:43.511Z" """
        |> decodeString date
    --> Date.fromString "2012-04-23T18:25:43.511Z"

    """ "foo" """
        |> decodeString date
    --> Err "I ran into a `fail` decoder: Unable to parse 'foo' as a date. Dates must be in the ISO 8601 format."

-}
date : Decoder Date.Date
date =
    string
        |> andThen (Date.fromString >> fromResult)


{-| Extract a set.

    "[ 1, 1, 5, 2 ]"
        |> decodeString (set int)
    --> Ok <| Set.fromList [ 1, 2, 5 ]

-}
set : Decoder comparable -> Decoder (Set comparable)
set decoder =
    list decoder
        |> map Set.fromList


{-| Extract a dict using separate decoders for keys and values.

    """ { "1": "foo", "2": "bar" } """
        |> decodeString (dict2 int string)
    --> Ok <| Dict.fromList [ ( 1, "foo" ), ( 2, "bar" ) ]

-}
dict2 : Decoder comparable -> Decoder v -> Decoder (Dict comparable v)
dict2 keyDecoder valueDecoder =
    keyValuePairs valueDecoder
        |> andThen (decodeDictFromTuples keyDecoder)


{-| Helper function for dict
-}
decodeDictFromTuples : Decoder comparable -> List ( String, v ) -> Decoder (Dict comparable v)
decodeDictFromTuples keyDecoder tuples =
    case tuples of
        [] ->
            succeed Dict.empty

        ( strKey, value ) :: rest ->
            case decodeString keyDecoder strKey of
                Ok key ->
                    decodeDictFromTuples keyDecoder rest
                        |> andThen (Dict.insert key value >> succeed)

                Err error ->
                    fail error


{-| Try running the given decoder; if that fails, then succeed with the given
fallback value.

    """ { "children": "oops" } """
        |> decodeString (field "children" (list string) |> withDefault [])
    --> Ok []

    """ null """
        |> decodeString (field "children" (list string) |> withDefault [])
    --> Ok []

    """ 30 """
        |> decodeString (int |> withDefault 42)
    --> Ok 30

-}
withDefault : a -> Decoder a -> Decoder a
withDefault fallback decoder =
    maybe decoder
        |> map (Maybe.withDefault fallback)


{-| If a field is missing, succeed with `Nothing`. If it is present, decode it
as normal and wrap successes in a `Just`.

When decoding with
[`maybe`](http://package.elm-lang.org/packages/elm-lang/core/latest/Json-Decode#maybe),
if a field is present but malformed, you get a success and Nothing.
`optionalField` gives you a failed decoding in that case, so you know
you received malformed data.

Examples:

Let's define a `stuffDecoder` that extracts the `"stuff"` field, if it exists.

    stuffDecoder : Decoder (Maybe String)
    stuffDecoder =
        optionalField "stuff" string

If the "stuff" field is missing, decode to Nothing.

    """ { } """
        |> decodeString stuffDecoder
    --> Ok Nothing

If the "stuff" field is present but not a String, fail decoding.

    """ { "stuff": [] } """
        |> decodeString stuffDecoder
    --> Err "Expecting a String at _.stuff but instead got: []"

If the "stuff" field is present and valid, decode to Just String.

    """ { "stuff": "yay!" } """
        |> decodeString stuffDecoder
    --> Ok <| Just "yay!"

-}
optionalField : String -> Decoder a -> Decoder (Maybe a)
optionalField fieldName decoder =
    let
        finishDecoding json =
            case decodeValue (field fieldName value) json of
                Ok val ->
                    -- The field is present, so run the decoder on it.
                    map Just (field fieldName decoder)

                Err _ ->
                    -- The field was missing, which is fine!
                    succeed Nothing
    in
    value
        |> andThen finishDecoding


{-| This function turns a list of decoders into a decoder that returns a list.

The returned decoder will zip the list of decoders with a list of values,
matching each decoder with exactly one value at the same position. This is most
often useful in cases when you find yourself needing to dynamically generate a
list of decoders based on some data, and decode some other data with this list
of decoders.

Note that this function, unlike `List.map2`'s behaviour, expects the list of
decoders to have the same length as the list of values in the JSON.

    sequence
        [ map Just string
        , succeed Nothing
        , map Just string
        ]
        |> flip decodeString """ [ "pick me", "ignore me", "and pick me" ] """
    --> Ok [ Just "pick me", Nothing, Just "and pick me" ]

-}
sequence : List (Decoder a) -> Decoder (List a)
sequence decoders =
    list value |> andThen (sequenceHelp decoders)


{-| Helper function for sequence
-}
sequenceHelp : List (Decoder a) -> List Value -> Decoder (List a)
sequenceHelp decoders jsonValues =
    if List.length jsonValues /= List.length decoders then
        fail "Number of decoders does not match number of values"
    else
        List.map2 decodeValue decoders jsonValues
            |> List.foldr (Result.map2 (::)) (Ok [])
            |> fromResult


{-| Get access to the current index while decoding a list element.

    repeatedStringDecoder : Int -> Decoder String
    repeatedStringDecoder times =
        string |> map (String.repeat times)

    """ [ "a", "b", "c", "d" ] """
        |> decodeString (indexedList repeatedStringDecoder)
    --> Ok [ "", "b", "cc", "ddd" ]

-}
indexedList : (Int -> Decoder a) -> Decoder (List a)
indexedList indexedDecoder =
    list value
        |> andThen
            (\values ->
                List.range 0 (List.length values - 1)
                    |> List.map indexedDecoder
                    |> sequence
            )


{-| Get a list of the keys of a JSON object

    decodeString keys "{ \"alice\": 42, \"bob\": 99 }"
        == [ "alice", "bob" ]
    --> True

-}
keys : Decoder (List String)
keys =
    keyValuePairs (succeed ())
        |> map (List.map Tuple.first)


{-| Transform a result into a decoder

Sometimes it can be useful to use functions that primarily operate on
`Result` in decoders. An example of this is `Json.Decode.Extra.date`. It
uses the built-in `Date.fromString` to parse a `String` as a `Date`, and
then converts the `Result` from that conversion into a decoder which has
either already succeeded or failed based on the outcome.

    validateString : String -> Result String String
    validateString input =
        case input of
            "" ->
                Err "Empty string is not allowed"
            _ ->
                Ok input

    """ "something" """
        |> decodeString (string |> andThen (fromResult << validateString))
    --> Ok "something"

    """ "" """
        |> decodeString (string |> andThen (fromResult << validateString))
    --> Err "I ran into a `fail` decoder: Empty string is not allowed"

-}
fromResult : Result String a -> Decoder a
fromResult result =
    case result of
        Ok successValue ->
            succeed successValue

        Err errorMessage ->
            fail errorMessage


{-| Extract an int using [`String.toInt`](http://package.elm-lang.org/packages/elm-lang/core/latest/String#toInt)

    """ { "field": "123" } """
        |> decodeString (field "field" parseInt)
    --> Ok 123

-}
parseInt : Decoder Int
parseInt =
    string |> andThen (String.toInt >> fromResult)


{-| Extract a float using [`String.toFloat`](http://package.elm-lang.org/packages/elm-lang/core/latest/String#toFloat)

    """ { "field": "50.5" } """
        |> decodeString (field "field" parseFloat)
    --> Ok 50.5

-}
parseFloat : Decoder Float
parseFloat =
    string |> andThen (String.toFloat >> fromResult)


{-| Extract a JSON-encoded string field

"Yo dawg, I heard you like JSON..."

If someone has put JSON in your JSON (perhaps a JSON log entry, encoded
as a string) this is the function you're looking for. Give it a decoder
and it will return a new decoder that applies your decoder to a string
field and yields the result (or fails if your decoder fails).

    logEntriesDecoder : Decoder (List String)
    logEntriesDecoder =
        doubleEncoded (list string)

    logsDecoder : Decoder (List String)
    logsDecoder =
        field "logs" logEntriesDecoder

    """ { "logs": "[\\"log1\\", \\"log2\\"]"} """
        |> decodeString logsDecoder
    --> Ok [ "log1", "log2" ]

-}
doubleEncoded : Decoder a -> Decoder a
doubleEncoded decoder =
    string |> andThen (fromResult << decodeString decoder)


{-| Helps convering a list of decoders into a decoder for a list of that type.

    decoders : List (Decoder String)
    decoders =
        [ field "foo" string
        , field "bar" string
        , field "another" string
        ]

    """ { "foo": "hello", "another": "!", "bar": "world" } """
        |> decodeString (combine decoders)
    --> Ok [ "hello", "world", "!" ]

-}
combine : List (Decoder a) -> Decoder (List a)
combine =
    List.foldr (map2 (::)) (succeed [])


{-| Some JavaScript structures look like arrays, but aren't really. Examples
include `HTMLCollection`, `NodeList` and everything else that has a `length`
property, has values indexed by an integer key between 0 and `length`, but yet
_is not_ a JavaScript Array.

This decoder can come to the rescue.

    """ { "length": 3, "0": "foo", "1": "bar", "2": "baz" } """
        |> decodeString (collection string)
    --> Ok [ "foo", "bar", "baz" ]

-}
collection : Decoder a -> Decoder (List a)
collection decoder =
    field "length" int
        |> andThen
            (\length ->
                List.range 0 (length - 1)
                    |> List.map (\index -> field (toString index) decoder)
                    |> combine
            )
