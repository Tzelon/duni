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

# *** Block level ***
statement -> exprStmt | printStmt | returnStmt | ifStmt | block;

# Not sure I want returnStmt
returnStmt -> "return" expression? ";" ;
ifStmt -> "if" "(" expression ")" statement ( "else" statement )? ;

block -> "{" statement* "}" ;

exprStmt -> expression NEWLINE ;
printStmt -> "print" expression ;

expression -> bind ;
# `=` is a binding (match), right-associative: `a = b = c` is `a = (b = c)`.
# The lhs is a pattern; rebinding an existing name is allowed (Elixir-style).
bind -> pattern "=" bind | logic_or ;
# Patterns are syntactically just expressions; which patterns are legal is
# decided during lowering (today: identifier only).
pattern -> expression ;

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
