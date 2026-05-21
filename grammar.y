program -> declaration* EOF ;

# *** Top level ***
declaration -> testDecl | funDecl | comptimeDecl;

testDecl -> "KEYWORD_test" STRING? block ;
comptimeDecl -> "KEYWORD_comptime" block ;
funDecl -> "KEYWORD_fn" function ;
function -> IDENTIFIER "(" parameters? ")" typeExpr block ;
parameters -> IDENTIFIER ( paramDecl "," )*  paramDecl;
paramDecl -> IDENTIFIER ":" typeExpr ; 
typeExpr -> IDENTIFIER ;

varDecl -> "IDENTIFIER "=" expression ;


# *** Block level ***
statement -> exprStmt | printStmt | returnStmt | ifStmt | block;

# Not sure I want returnStmt
returnStmt -> "return" expression? ";" ;
ifStmt -> "if" "(" expression ")" statement ( "else" statement )? ;

block -> "{" statement* "}" ;

exprStmt -> expression "\n" ;
printStmt -> "print" expression ;

expression -> equality ;
assignment -> (call ".")? IDENTIFIER "=" assignment | logic_or ;

logic_or -> logic_and ( "or" logic_and )* ;
logic_and -> equality ( "and" equality )* ;

equality ->  comparison ( ("!=" | "==") comparison )* ;
comparison -> term ( (">" | ">=" | "<" | "<=") term )* ;
term -> factor ( ("-" | "+") factor )* ;
factor -> unary ( ("/" | "*") unary )* ;
unary -> ("-", "!") unary | call ;
call -> primary ( "(" arguments? ")" | "." IDENTIFIER )* ;
arguments -> expression ( "," expression )* ;
primary -> NUMBER | STRING | "true" | "false" | "nil" | "this" | "(" expression ")" | IDENTIFIER | "super" "." IDENTIFIER ;
