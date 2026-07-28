import React,{forwardRef}from"react";

function normalizeDecimal(value){
  return String(value??"")
    .replace(/[٠-٩]/g,d=>String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))
    .replace(/[٫,]/g,".")
    .replace(/[^0-9.-]/g,"")
    .replace(/(?!^)-/g,"")
    .replace(/(\..*)\./g,"$1");
}

export const NumericInput=forwardRef(function NumericInput({onChange,allowNegative=false,style,...props},ref){
  function handleChange(event){
    let next=normalizeDecimal(event.target.value);
    if(!allowNegative)next=next.replace(/-/g,"");
    event.target.value=next;
    onChange?.(event);
  }
  return <input
    {...props}
    ref={ref}
    type="text"
    inputMode="decimal"
    autoComplete="off"
    dir="ltr"
    className={["nui-numeric-input",props.className].filter(Boolean).join(" ")}
    style={{textAlign:"right",...style}}
    onChange={handleChange}
  />;
});
